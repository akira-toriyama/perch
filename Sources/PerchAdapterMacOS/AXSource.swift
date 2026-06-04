// `UIElementSource` for real macOS apps.
//
// On every `enumerate()` call we:
//   1. Resolve the frontmost app via NSWorkspace.
//   2. Get its focused window via AXUIElement(kAXFocusedWindow).
//   3. Capture the window's frame so we can drop AX nodes whose
//      visible position is outside the window (Electron / web AX
//      trees expose a lot of off-screen content and we don't
//      want pills floating over the desktop).
//   4. Walk the AX subtree of that window, depth-first.
//   5. Keep only nodes whose role (without `AX`) is in `roles`,
//      that support `kAXPressAction` (rules out decorative
//      divs that map to a role but don't actually click), and
//      whose frame intersects the window's frame.
//   6. De-duplicate near-overlapping pills (within `proximityPx`)
//      so a tightly nested AX tree doesn't pile a wall of pills
//      on the same visible button.
//   7. Build a backend-neutral `UIElement` for each survivor;
//      store the live `AXUIElement` in a side-table keyed by the
//      same synthetic id so a later `act(id:as:)` can resolve back.
//
// Core never sees `AXUIElement` — same policy as stroke / facet.
// The side-table is owned by this adapter and cleared at the start
// of every enumeration so we don't leak stale handles after the
// frontmost focus moves.

import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import PerchCore

public final class AXUIElementSource: UIElementSource, @unchecked Sendable {

    // Whole config snapshot, kept so we can resolve per-app overrides
    // (`[behavior."<bundle-id>"]`) at enumerate-time against the
    // currently-frontmost app. Per-app overrides change the role
    // allow-list and the min-size floor per enumeration; without the
    // full config we'd need to plumb the lookup map separately.
    private var config: PerchConfig

    // Roles to label outside `AXWebArea` subtrees. Snapshot of the
    // *global* `[behavior].roles` plus the active per-app override
    // (resolved at the top of each `enumerate()`). The walker reads
    // this; the enumerate path mutates it briefly.
    private var roles: Set<String>

    // Roles to label inside `AXWebArea` subtrees, configured by
    // `[behavior.web].roles`. Falls back to the native list when
    // the user hasn't opted in — so untouched configs behave
    // exactly like before. Swap point: `WalkCtx.inWebArea`.
    private var webRoles: Set<String>

    // Bundle IDs perch refuses to label (e.g. apps with their own
    // keyboard nav). Empty in the default config.
    private var excludes: Set<String>

    // Floor for AX-element frame size (points, either axis).
    // Anything smaller falls out of `frameOf` and never reaches the
    // role / press / window filters. Like `roles`, this is mutated
    // per `enumerate()` to apply per-app overrides.
    private var minSize: CGFloat

    // (id → live AXUIElement) — only valid for the most recent
    // enumeration. Re-cleared at the top of every `enumerate()`.
    private var liveById: [String: AXUIElement] = [:]

    // Monotonic counter so each enumerated element gets a unique
    // string id without needing to hash the opaque AXUIElement.
    // Reset at the top of every `enumerate()` along with `liveById`.
    private var nextSeq: Int = 0

    // Recursion guards. AX trees are typically a few hundred nodes
    // for a native window; we cap deep recursions so a buggy app
    // can't lock the daemon in an enumeration storm.
    //
    // `nativeMaxDepth` is the everyday ceiling for AppKit / SwiftUI
    // hierarchies. `webMaxDepth` raises the ceiling once the walker
    // crosses into an `AXWebArea` subtree — web DOM trees are often
    // 40-60 levels deep before a clickable leaf (per investigations
    // surfaced by issue #26), and the native cap was eating the
    // whole page when the user expected hint pills on links. Both
    // are absolute depth ceilings; the higher value applies for the
    // rest of the descent once a web area is entered.
    private let nativeMaxDepth = 32
    private let webMaxDepth = 64

    /// Two elements whose top-left corners are within this many
    /// points are considered "the same visible target" for the
    /// purposes of de-duplication. AX trees from web-shell apps
    /// (Cursor, VS Code, Slack) often expose a stack of 3-5 nodes
    /// at the same place (container ➜ wrapper ➜ button); we keep
    /// the first one that supports `kAXPressAction` and drop the
    /// rest. 8pt is still tight enough not to collapse genuinely
    /// adjacent toolbar buttons (those are typically ≥ 20pt apart
    /// on macOS).
    private let proximityPx: CGFloat = 8

    /// Window frame captured at the top of each `enumerate()` for
    /// the in-bounds filter. `.zero` means "no clipping" (we
    /// couldn't read the window's frame for some reason — falls
    /// open rather than hiding everything).
    private var windowFrame: CGRect = .zero

    /// Pids we've already flipped `AXManualAccessibility = true` on.
    /// Chrome / Electron expose nothing under their `AXWebArea`
    /// until an AX client signals interest via this attribute —
    /// without it, the page DOM is invisible to perch (see issue
    /// #26 — empty raw dump for Chrome). Once per pid: the flip
    /// is idempotent, but we also use this to suppress the
    /// per-activation log line.
    private var wokenPids: Set<pid_t> = []

    /// Pids we've flipped `AXEnhancedUserInterface = true` on
    /// (the heavier wake signal — what VoiceOver flips). Tracked
    /// separately from `wokenPids` so a bundle that promotes via
    /// runtime WebArea discovery (issue #38) gets the Enhanced
    /// flip on its NEXT enumerate, not "never, because Manual
    /// already ran on the first sighting". Reverse-flipped on
    /// `clearRendererWake()` so perch doesn't leak the Enhanced
    /// bit past its own lifetime (issue #33).
    private var enhancedPids: Set<pid_t> = []

    /// Pids we've explicitly prewarm-walked at app-activation time.
    /// Chrome's renderer-AX populates asynchronously after the
    /// first query — without prewarm the first hotkey on a freshly-
    /// focused window enumerates only the browser chrome (issue
    /// #28). One-shot per pid; daemon restart resets.
    private var prewarmedPids: Set<pid_t> = []

    /// Bundles outside `chromiumPrefixes` where the walker has
    /// observed an `AXWebArea` during a real enumeration — Books,
    /// Mac App Store, Slack notification flyouts, native apps with
    /// an embedded WKWebView marketing pane, etc. (issue #38).
    /// Treated as honorary Chromium bundles for the wake / prewarm
    /// gates so subsequent activations get the renderer signal too.
    ///
    /// Discovery is **observation-based**, not bundle-id heuristic:
    /// only apps that actually surface a WebArea ever land here, so
    /// the Office-typing-latency caveat that gates the static
    /// allow-list doesn't apply.
    ///
    /// Session-lifetime; cleared on daemon restart. Exposed read-only
    /// to `Controller.writeStatus(...)` so `perch --status` can
    /// surface the list for triage.
    private var discoveredWebBundles: Set<String> = []

    /// Bundle id of the most recent `enumerate()` invocation
    /// (assigned at the top of `enumerate()` once the frontmost
    /// app is resolved). Three consumers:
    ///
    ///   1. **During the walk** — the recursive `walk()` reads this
    ///      to attribute a `WebArea` crossing to the right bundle
    ///      (#38) without threading the id through every `WalkCtx`.
    ///   2. **After the walk** — `Controller` reads this to pass the
    ///      identity `enumerate()` made its per-app decisions
    ///      against (#37) down to `OverlayWindow.show`, avoiding a
    ///      NSWorkspace re-resolve that could race with a focus
    ///      switch and produce inconsistent overrides across the
    ///      enumerate / auto-click branches.
    ///   3. **Per-app override resolution itself** — `enumerate()`
    ///      reads `config.effectiveX(for: lastEnumeratedBundleID)`
    ///      against the freshly-set value (#37).
    ///
    /// `nil` until the first enumeration; never cleared between
    /// enumerations (a stale value past a subsequent enumerate is
    /// overwritten by the new one, and all consumers above only
    /// read it in a window where it's correctly set).
    public private(set) var lastEnumeratedBundleID: String?

    public init(config: PerchConfig) {
        self.config = config
        self.roles = Set(config.roles)
        self.webRoles = Set(config.webRoles)
        self.excludes = Set(config.excludeApps)
        self.minSize = CGFloat(config.minSize)
    }

    public func updateConfig(_ cfg: PerchConfig) {
        self.config = cfg
        self.roles = Set(cfg.roles)
        self.webRoles = Set(cfg.webRoles)
        self.excludes = Set(cfg.excludeApps)
        self.minSize = CGFloat(cfg.minSize)
    }

    /// Read-only snapshot of WKWebView-bearing bundles discovered
    /// during this daemon's lifetime (issue #38). Used by
    /// `Controller.writeStatus(...)` so `perch --status` can surface
    /// the list as a triage aid ("which non-Chromium apps does perch
    /// know to wake?"). Sorted for stable output.
    public var discoveredWebBearingBundles: [String] {
        Array(discoveredWebBundles).sorted()
    }

    /// Reverse the renderer wake-up on every pid we've flipped
    /// `AXEnhancedUserInterface = true` on during the daemon's
    /// lifetime. Called at clean shutdown (`perch --quit`) so we
    /// don't leak Chromium / Electron AX bookkeeping state past
    /// perch's process boundary.
    ///
    /// Pids that have died since are silently skipped — the AX set
    /// call on a stale `AXUIElementCreateApplication` handle just
    /// returns an error, no crash.
    ///
    /// We don't try to clear `AXManualAccessibility` because Chrome
    /// rejected it on the way in (`kAXErrorAttributeUnsupported`) —
    /// there's nothing to clear.
    public func clearRendererWake() {
        // Reverse only the Enhanced flip — Manual rejects on Chrome
        // anyway, so there's nothing to clear on that latch. Iterate
        // `enhancedPids` (the pids we actually flipped) rather than
        // `wokenPids` (the broader Manual set), so a non-Web-bearing
        // app whose Manual latch we touched doesn't get a spurious
        // Enhanced=false write.
        let pids = enhancedPids
        wokenPids.removeAll()
        enhancedPids.removeAll()
        prewarmedPids.removeAll()
        // Discovery set is in-memory only — clearing here keeps the
        // `--status` line honest (no stale "discovered" entries
        // after a `--quit` would never re-walk them).
        discoveredWebBundles.removeAll()
        guard !pids.isEmpty else { return }
        for pid in pids {
            let app = AXUIElementCreateApplication(pid)
            _ = AXUIElementSetAttributeValue(
                app,
                "AXEnhancedUserInterface" as CFString,
                kCFBooleanFalse)
        }
        Log.line("ax: cleared renderer-wake on \(pids.count) pid(s)")
    }

    /// Wake the renderer-accessibility tree of a Chromium / Electron
    /// app proactively, so the *first* hotkey activation after the
    /// app gains focus sees the populated `AXWebArea` instead of
    /// just the browser chrome.
    ///
    /// Chrome's renderer-AX populates **asynchronously** after the
    /// first AX query lands. Without prewarm the user pattern is
    /// "switch to Chrome → press hotkey → see ~20 hints (browser
    /// shell only) → dismiss → press hotkey → see 180+ hints
    /// (page included)". This call removes the first miss.
    ///
    /// Gated to the same bundle-id allow-list as the Enhanced wake
    /// in `enumerate()` — Office apps would slow under the wake
    /// signal, and the prewarm is only useful for apps that *have*
    /// a renderer to wake. No-op for everything else, no-op for
    /// already-prewarmed pids (one-shot per daemon lifetime).
    ///
    /// Side effects:
    ///   - flips `AXManualAccessibility` + (Chromium-gated)
    ///     `AXEnhancedUserInterface` on the app element
    ///   - reads `kAXFocusedWindow` and its `kAXChildren` — the
    ///     minimal query the renderer needs to register interest
    ///   - leaves no UIElement state behind (does not touch
    ///     `liveById` / `nextSeq` — those are owned by `enumerate()`)
    public func prewarm(pid: pid_t, bundleID: String) {
        // Static Chromium allow-list OR a runtime-discovered
        // WebView-bearing bundle (issue #38). The discovered set
        // can only grow once we've enumerated the app at least
        // once, so the very first activation from cold start still
        // misses — but the second one onward gets the prewarm too.
        guard isWebBearing(bundleID) else { return }
        guard !prewarmedPids.contains(pid) else { return }
        prewarmedPids.insert(pid)

        let appElt = AXUIElementCreateApplication(pid)
        // Mirror the wake calls in `enumerate()` — same rationale
        // (Chrome rejects but the act of accessing the element is
        // itself the wake trigger; future Chromium builds might
        // honour the attribute).
        let errM = AXUIElementSetAttributeValue(
            appElt, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        let errE = AXUIElementSetAttributeValue(
            appElt, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        // Latch both flips so a subsequent `enumerate()` skips the
        // wake block instead of re-flipping (idempotent, but the
        // duplicate `ax: wake → …` log line is misleading).
        wokenPids.insert(pid)
        enhancedPids.insert(pid)

        // Lightweight AX query: focused window + its direct
        // children. Chromium populates the renderer-AX from this
        // hop; deeper walking happens later under enumerate().
        var focusedRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            appElt, kAXFocusedWindowAttribute as CFString, &focusedRef)
        if let f = focusedRef,
           CFGetTypeID(f) == AXUIElementGetTypeID() {
            let window = f as! AXUIElement
            var kidsRef: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(
                window, kAXChildrenAttribute as CFString, &kidsRef)
        }
        Log.line("ax: prewarm → \(bundleID) "
                 + "manual=\(errM.rawValue) enhanced=\(errE.rawValue)")
    }

    // MARK: - UIElementSource

    public func enumerate() -> [UIElement] {
        guard let root = prepareWalkRoot() else { return [] }
        // Per-app overrides (#37) fold directly into the policy —
        // unset keys fall through to the global value via
        // `effectiveX(for:)` (typo-tolerance preserved). No more
        // save/restore of `self.roles` / `self.minSize` is needed:
        // the policy IS the resolved state for this enumeration.
        let effRoles = config.effectiveRoles(for: root.bundleID)
        let effMinSize = CGFloat(
            config.effectiveMinSize(for: root.bundleID))
        if config.perApp[root.bundleID] != nil {
            Log.debug("ax: per-app override \(root.bundleID) "
                      + "roles=\(effRoles.count) "
                      + "min-size=\(Int(effMinSize))")
        }
        let policy = WalkPolicy(
            nativeRoles: Set(effRoles),
            webRoles: webRoles,
            minWidth: effMinSize,
            minHeight: effMinSize,
            requirePress: true)
        return runWalk(window: root.window, policy: policy,
                       label: "hint", bundleID: root.bundleID,
                       pid: root.pid)
    }

    /// Issue #34 — regional hint mode. Same setup as `enumerate()`
    /// but with the role allow-list swapped for large containers
    /// (`Group` / `Article` / `Section` / `SplitGroup` / `ScrollArea`
    /// / `Outline` / `Image`), a 200×100 frame floor, and
    /// `kAXPressAction` no longer required — regional picks land on
    /// `.copyTitle` / `.focus` / `.rightClick` against containers
    /// that usually aren't pressable.
    public func enumerateRegions() -> [UIElement] {
        guard let root = prepareWalkRoot() else { return [] }
        let policy = WalkPolicy(
            nativeRoles: Self.regionalRoles,
            webRoles: Self.regionalRoles,
            minWidth: 200,
            minHeight: 100,
            requirePress: false)
        return runWalk(window: root.window, policy: policy,
                       label: "region", bundleID: root.bundleID,
                       pid: root.pid)
    }

    // MARK: - Shared walk setup

    /// Reset per-enumeration state + resolve frontmost / wake gate
    /// / focused window / bounds. Returns the AX `window` to walk
    /// plus the bundle id and pid for downstream logging. Returns
    /// `nil` when there's no eligible window (no frontmost app,
    /// excluded bundle, no focused window) — the caller treats
    /// that as a no-op enumeration.
    private func prepareWalkRoot() -> (
        window: AXUIElement, bundleID: String, pid: pid_t
    )? {
        liveById.removeAll(keepingCapacity: true)
        nextSeq = 0

        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier
        else {
            Log.debug("ax: no frontmost app")
            return nil
        }
        if excludes.contains(bundleID) {
            Log.debug("ax: excluded app \(bundleID)")
            return nil
        }
        Log.debug("ax: front=\(bundleID) pid=\(front.processIdentifier)")
        // Capture the bundle id this enumeration is committed to so
        // the walker (WebArea attribution, #38), the Controller
        // (OverlayWindow.show, #37), and per-app override resolution
        // can all read the SAME identity without re-resolving
        // NSWorkspace.
        self.lastEnumeratedBundleID = bundleID

        let appElt = AXUIElementCreateApplication(front.processIdentifier)

        // Wake the renderer-accessibility tree on Chromium-based
        // apps (Chrome / Edge / Brave / Arc / VS Code / Slack /
        // Discord / Electron in general). They keep their page /
        // content `AXWebArea` collapsed until an AX client signals
        // interest. Without a wake the raw AX tree for a Chrome
        // window has zero `*WEB*` markers — the page DOM is
        // completely invisible to perch.
        //
        // Two attributes flip the switch, **each gated by its own
        // per-pid latch** so runtime WebArea discovery (issue #38)
        // can promote a bundle and have the Enhanced flip fire on
        // the *next* enumerate even though Manual already ran:
        //
        //   1. `AXManualAccessibility` — the lighter knob,
        //      preferred when the app supports it. Chrome currently
        //      returns `kAXErrorAttributeUnsupported` (-25205) when
        //      we try to set it on the app element, so this is
        //      kept as best-effort. Latched via `wokenPids`.
        //   2. `AXEnhancedUserInterface` — what VoiceOver flips.
        //      Chromium / Electron honour it. Known to cause
        //      sustained perf hits in Microsoft Office apps (Word
        //      / Excel reroute event handling through assistive
        //      tech APIs while it's on), so we **only** set this
        //      on bundles `isWebBearing(_:)` recognises (static
        //      Chromium allow-list ∪ runtime-discovered WebArea
        //      hosts). Latched separately via `enhancedPids`.
        //
        // First activation after wake may still see an empty
        // subtree — Chrome populates the renderer AX
        // asynchronously, typically within a few hundred ms. By
        // the second activation the content is there.
        if !wokenPids.contains(front.processIdentifier) {
            let errM = AXUIElementSetAttributeValue(
                appElt,
                "AXManualAccessibility" as CFString,
                kCFBooleanTrue)
            wokenPids.insert(front.processIdentifier)
            Log.line("ax: wake → \(bundleID) manual=\(errM.rawValue)")
        }
        if isWebBearing(bundleID),
           !enhancedPids.contains(front.processIdentifier) {
            let errE = AXUIElementSetAttributeValue(
                appElt,
                "AXEnhancedUserInterface" as CFString,
                kCFBooleanTrue)
            enhancedPids.insert(front.processIdentifier)
            Log.line("ax: enhanced → \(bundleID) result=\(errE.rawValue)")
        }

        guard let focused = copyAttribute(appElt, kAXFocusedWindowAttribute),
              CFGetTypeID(focused as CFTypeRef) == AXUIElementGetTypeID()
        else {
            Log.debug("ax: no focused window for \(bundleID)")
            return nil
        }
        let window = focused as! AXUIElement   // checked via AXUIElementGetTypeID
        // Belt + braces bounds for filtering:
        //   - CGWindow bounds (Quartz's view of the visible window)
        //   - AX kAXPosition+kAXSize (per-app reported frame)
        // Intersect them with `NSScreen.main.visibleFrame` (the
        // user-usable area = screen minus menu bar minus a Dock
        // that isn't auto-hidden) so even when an app over-reports
        // its window frame to span the menu bar or Dock area, the
        // visible-screen intersection clips us back to what the
        // user can actually see.
        let cgFrame = onScreenBounds(forPid: front.processIdentifier)
        // Window's own frame is read with min-size 0 — the bounds
        // calc must not drop the root just because it's small.
        let axFrame = rawFrameOf(window, minWidth: 0, minHeight: 0)
        let baseFrame = cgFrame ?? axFrame ?? .zero
        windowFrame = clampToVisibleScreen(baseFrame)
        // Promoted to Log.line so the diagnostic shows up under
        // release runs too — invaluable when triaging "pills
        // outside the window" reports without asking the user to
        // re-launch with PERCH_DEBUG=1.
        Log.line("ax: bounds "
                 + "cg=\(cgFrame.map(OverlayCoords.rectString) ?? "nil") "
                 + "ax=\(axFrame.map(OverlayCoords.rectString) ?? "nil") "
                 + "→ filter=\(OverlayCoords.rectString(windowFrame))")

        return (window, bundleID, front.processIdentifier)
    }

    /// Run the policy-driven walk + dedup, prune `liveById`, log
    /// the result. Shared between `enumerate()` (hint mode) and
    /// `enumerateRegions()` (#34) — the only thing that varies is
    /// the `WalkPolicy`.
    private func runWalk(
        window: AXUIElement,
        policy: WalkPolicy,
        label: String,
        bundleID: String,
        pid: pid_t
    ) -> [UIElement] {
        var raw: [UIElement] = []
        let ctx = WalkCtx(maxDepth: nativeMaxDepth, inWebArea: false)
        walk(window, depth: 0, ctx: ctx, policy: policy,
             pid: pid, into: &raw)
        let pruned = dedupNearOverlaps(raw)
        if pruned.count != raw.count {
            Log.debug("ax: de-dup \(raw.count) → \(pruned.count)")
        }
        // Rebuild liveById so dropped ids don't keep stale AXUIElement
        // handles around — the dedup loop keeps the FIRST element at
        // each cluster, so we just remove the dropped ids.
        let kept = Set(pruned.map(\.id))
        for id in liveById.keys where !kept.contains(id) {
            liveById.removeValue(forKey: id)
        }
        Log.line("ax: enumerated \(pruned.count) \(label)(s) "
                 + "in \(bundleID)")
        return pruned
    }

    public func act(id: String, as action: HintAction) -> Bool {
        guard let elt = liveById[id] else {
            Log.line("dispatch: no live element for id=\(id)")
            return false
        }
        switch action {
        case .press, .pressContinuous:
            // Same AX dispatch as a plain press — `.pressContinuous`
            // diverges only in what the controller does AFTER (it
            // re-shows hints). The adapter-side semantics are
            // identical so the AXPress branch is shared.
            return perform(elt, action: kAXPressAction as CFString,
                           tag: "AXPress", id: id)
        case .rightClick:
            return perform(elt, action: kAXShowMenuAction as CFString,
                           tag: "AXShowMenu", id: id)
        case .focus:
            // kAXFocusedAttribute is a boolean attribute, not an
            // action — settable via AXUIElementSetAttributeValue.
            let err = AXUIElementSetAttributeValue(
                elt, kAXFocusedAttribute as CFString,
                kCFBooleanTrue)
            if err == .success {
                Log.line("dispatch: AXFocus ok → id=\(id)")
                return true
            }
            Log.line("dispatch: AXFocus failed (\(err.rawValue)) → id=\(id)")
            return false
        case .copyTitle:
            // Resolve title from the side-table'd UIElement.label
            // would require keeping it post-enumeration; cheaper
            // to re-read the live attribute at copy time.
            let title = (copyAttribute(elt, kAXTitleAttribute) as? String)
                ?? (copyAttribute(elt, kAXValueAttribute) as? String)
                ?? ""
            guard !title.isEmpty else {
                Log.line("dispatch: copyTitle empty → id=\(id)")
                return false
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(title, forType: .string)
            Log.line("dispatch: copyTitle ok (\(title.count) chars) → id=\(id)")
            return true
        }
    }

    /// Common path for the two action verbs that both go through
    /// `AXUIElementPerformAction` — folds the success / failure
    /// log into one place.
    private func perform(
        _ elt: AXUIElement, action: CFString, tag: String, id: String
    ) -> Bool {
        let err = AXUIElementPerformAction(elt, action)
        if err == .success {
            Log.line("dispatch: \(tag) ok → id=\(id)")
            return true
        }
        Log.line("dispatch: \(tag) failed (\(err.rawValue)) → id=\(id)")
        return false
    }

    // MARK: - Internals

    /// Recursion context. Carries the depth ceiling so we can swap
    /// it (native → web) for the rest of a subtree without leaking
    /// the change up to siblings.
    private struct WalkCtx {
        let maxDepth: Int
        let inWebArea: Bool
    }

    /// Per-enumeration filter knobs. Built fresh in `enumerate()` /
    /// `enumerateRegions()` so each mode pins its own role list,
    /// size floor, and press-support rule without touching the
    /// instance state used by other call sites.
    private struct WalkPolicy {
        /// Roles to accept outside an `AXWebArea`. Hint mode uses
        /// `[behavior].roles`; regional mode uses `regionalRoles`.
        let nativeRoles: Set<String>
        /// Roles to accept inside an `AXWebArea` subtree. Hint mode
        /// uses `[behavior.web].roles`; regional mode uses the
        /// same `regionalRoles` set (Group/Article/Section etc.
        /// work identically in web context).
        let webRoles: Set<String>
        /// Reject elements whose frame is narrower than this on
        /// the X axis.
        let minWidth: CGFloat
        /// Reject elements whose frame is shorter than this on
        /// the Y axis. Separate from `minWidth` so regional mode
        /// can demand a "200×100" landscape minimum (issue #34
        /// — articles are wide but not very tall).
        let minHeight: CGFloat
        /// If `true`, the element must advertise `kAXPressAction`
        /// (or `kAXShowMenuAction`). False for regional mode, where
        /// the action is usually `.copyTitle` / `.focus` against a
        /// container that doesn't press.
        let requirePress: Bool
    }

    private func walk(
        _ node: AXUIElement,
        depth: Int,
        ctx: WalkCtx,
        policy: WalkPolicy,
        pid: pid_t,
        into out: inout [UIElement]
    ) {
        if depth > ctx.maxDepth { return }

        // Role check — keep it cheap, before reading frame / title.
        let rawRole = (copyAttribute(node, kAXRoleAttribute) as? String) ?? ""
        let role = rawRole.hasPrefix("AX")
            ? String(rawRole.dropFirst(2)) : rawRole

        // Inside a web area the role allow-list switches to the
        // policy's `webRoles`; outside, `nativeRoles`. Same set in
        // regional mode (containers behave identically in web vs
        // native context); hint mode diverges when the user tunes
        // `[behavior.web].roles` separately.
        let activeRoles = ctx.inWebArea ? policy.webRoles : policy.nativeRoles
        if activeRoles.contains(role),
           let frame = rawFrameOf(node,
                                  minWidth: policy.minWidth,
                                  minHeight: policy.minHeight),
           !policy.requirePress || supportsPress(node),
           insideWindow(frame) {
            let title = (copyAttribute(node, kAXTitleAttribute) as? String)
                ?? (copyAttribute(node, kAXValueAttribute) as? String)
                ?? ""
            nextSeq += 1
            let id = "\(pid):\(nextSeq)"
            liveById[id] = node
            out.append(UIElement(
                id: id, role: role, label: title, frame: frame))
        }

        // Crossing into a web area lifts the depth ceiling for the
        // rest of this subtree. Chromium / WKWebView trees routinely
        // bury clickable leaves 40+ levels below the AXWebArea, well
        // past the native cap — keep the cap for the rest of the
        // native UI but relax it locally here. Log once per crossing
        // so triage of "perch saw the web area but no links" is
        // direct.
        var nextCtx = ctx
        if !ctx.inWebArea && role == "WebArea" {
            Log.line("ax: web-area entered at depth=\(depth) "
                     + "→ maxDepth \(ctx.maxDepth) → \(webMaxDepth)")
            nextCtx = WalkCtx(maxDepth: webMaxDepth, inWebArea: true)

            // Issue #38 — first WebArea sighting in a bundle that
            // isn't in the static Chromium allow-list flags the
            // bundle as web-bearing for the rest of this daemon's
            // lifetime. Subsequent activations get the renderer
            // wake / prewarm path that Chromium bundles already
            // enjoy. Log once per bundle so the line is the obvious
            // signal "perch just promoted this bundle".
            if let bid = lastEnumeratedBundleID,
               !Self.isChromiumBundle(bid),
               !discoveredWebBundles.contains(bid) {
                discoveredWebBundles.insert(bid)
                Log.line(
                    "ax: WebArea in non-listed bundle "
                    + "\(bid) → promoted")
            }
        }

        // Recurse: prefer `kAXVisibleChildrenAttribute` when the
        // node exposes it — that's the AX subset that's actually
        // on screen right now, which dramatically cuts the noise
        // from scroll-area / web-shell trees (Cursor / VS Code /
        // Slack expose every scrolled-out DOM child via plain
        // `kAXChildren`; pre-filter via `kAXVisibleChildren` lets
        // us skip walking them in the first place). Plain
        // `kAXChildren` is the universal fallback.
        let children = visibleChildrenIfAvailable(of: node)
        for child in children {
            walk(child, depth: depth + 1, ctx: nextCtx,
                 policy: policy, pid: pid, into: &out)
        }
    }

    /// `kAXVisibleChildren` first; `kAXChildren` if the node
    /// doesn't expose the visible-only subset. Returning `[]` is
    /// fine — the walker just stops recursing through this node.
    private func visibleChildrenIfAvailable(
        of node: AXUIElement
    ) -> [AXUIElement] {
        if let v = copyAttribute(node, kAXVisibleChildrenAttribute)
                    as? [AXUIElement], !v.isEmpty {
            return v
        }
        return (copyAttribute(node, kAXChildrenAttribute)
                  as? [AXUIElement]) ?? []
    }

    /// Position + size of an AX node, in screen coordinates (top-left
    /// origin to match Cocoa's screen rect convention used by the
    /// overlay panel). `minWidth` / `minHeight` come from the active
    /// `WalkPolicy`; nodes failing either threshold return `nil`.
    ///
    /// Pass `0` for both when reading the frame of the focused
    /// window itself (the bounds-calc helper) — the window must not
    /// be dropped just because it's small on some axis.
    private func rawFrameOf(
        _ node: AXUIElement,
        minWidth: CGFloat,
        minHeight: CGFloat
    ) -> CGRect? {
        guard let posAny = copyAttribute(node, kAXPositionAttribute),
              let sizeAny = copyAttribute(node, kAXSizeAttribute),
              CFGetTypeID(posAny as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(sizeAny as CFTypeRef) == AXValueGetTypeID()
        else { return nil }
        let pos = posAny as! AXValue       // checked via AXValueGetTypeID
        let size = sizeAny as! AXValue
        var p = CGPoint.zero
        var s = CGSize.zero
        guard AXValueGetValue(pos, .cgPoint, &p),
              AXValueGetValue(size, .cgSize, &s)
        else { return nil }
        if s.width < minWidth || s.height < minHeight { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Wrapper around `AXUIElementCopyAttributeValue` that returns
    /// the value as a Swift `Any?` for ergonomics.
    private func copyAttribute(
        _ node: AXUIElement, _ name: String
    ) -> Any? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(
            node, name as CFString, &value)
        guard err == .success else { return nil }
        return value
    }

    /// `true` when the element advertises `kAXPressAction` (or
    /// `kAXShowMenuAction` — those are the two activation paths
    /// perch can dispatch). Filters out role-bearing-but-inert
    /// elements, which are common in web-shell apps where
    /// containers report a "Button" role without supporting click.
    private func supportsPress(_ node: AXUIElement) -> Bool {
        var actions: CFArray?
        let err = AXUIElementCopyActionNames(node, &actions)
        guard err == .success,
              let names = actions as? [String]
        else {
            // Couldn't read the action list — be permissive (keep
            // the element) rather than hide a legitimate hint.
            return true
        }
        return names.contains(kAXPressAction as String)
            || names.contains(kAXShowMenuAction as String)
    }

    /// `true` when `frame`'s CENTRE is inside the focused window's
    /// frame. Stricter than `intersects` — drops elements that
    /// dangle off the visible window (the off-screen scroll tail
    /// of a large AX tree, hidden modal backers, items still in
    /// the tree from a recent resize). Falls open (always true)
    /// when we couldn't read the window's frame.
    private func insideWindow(_ frame: CGRect) -> Bool {
        guard windowFrame.width > 0, windowFrame.height > 0
        else { return true }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        return windowFrame.contains(centre)
    }

    /// Quartz-level on-screen bounds for the topmost normal-layer
    /// window of `pid`. Returned in top-left-origin screen coords
    /// (same convention as AX `kAXPosition`). Returns `nil` when
    /// the app has no on-screen windows (Quartz hasn't indexed it
    /// yet, or the process is purely background).
    private func onScreenBounds(forPid pid: pid_t) -> CGRect? {
        let opts: CGWindowListOption = [.optionOnScreenOnly,
                                         .excludeDesktopElements]
        guard let infos
            = CGWindowListCopyWindowInfo(opts, kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }
        for info in infos {
            guard let owner = info[kCGWindowOwnerPID as String] as? pid_t,
                  owner == pid,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let b = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"],
                  let w = b["Width"], let h = b["Height"],
                  w > 0, h > 0
            else { continue }
            return CGRect(x: x, y: y, width: w, height: h)
        }
        return nil
    }

    /// Intersect `rect` with `NSScreen.main.visibleFrame` (the
    /// user-usable area: screen minus menu bar minus an on-Dock).
    /// Returns the clipped rect in **top-left-origin** screen
    /// coords (same convention AX uses), so it lines up with AX
    /// element frames at filter time. `visibleFrame` itself is in
    /// Cocoa (Y-up) coords keyed off the *primary* display's
    /// bottom-left, so a sign-flip via the primary screen height
    /// is the conversion.
    private func clampToVisibleScreen(_ rect: CGRect) -> CGRect {
        guard let main = NSScreen.main else { return rect }
        let vis = main.visibleFrame
        let totalH = main.frame.height
        // Cocoa → CG. visibleFrame.maxY (Cocoa) is the y of the
        // visibleFrame's TOP edge from primary bottom; subtract
        // from totalH to get the same edge measured from primary
        // TOP — that's our CG y for the visible-area top.
        let cgVis = CGRect(
            x: vis.origin.x,
            y: totalH - vis.maxY,
            width: vis.width,
            height: vis.height)
        return rect.intersection(cgVis)
    }

    /// Bundle IDs that warrant flipping `AXEnhancedUserInterface`
    /// to wake the renderer-accessibility tree. Chromium browsers
    /// + the Electron apps perch users routinely reach for. Not
    /// exhaustive — extending the list is the cheapest way to add
    /// web-content coverage to a newly-reported app, no other code
    /// change needed.
    private static let chromiumPrefixes: [String] = [
        // Chromium browsers
        "com.google.Chrome",
        "com.microsoft.edgemac",
        "org.chromium",
        "com.brave.Browser",
        "company.thebrowser.Browser",   // Arc
        "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
        // Electron apps
        "com.microsoft.VSCode",
        "com.todesktop.",                // Cursor, others
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.figma.Desktop",
        "com.spotify.client",
        "com.notion.id",
    ]

    static func isChromiumBundle(_ bundleID: String) -> Bool {
        chromiumPrefixes.contains { bundleID.hasPrefix($0) }
    }

    /// `true` when `bundleID` is either in the static Chromium /
    /// Electron allow-list OR a runtime-discovered WKWebView host
    /// (issue #38). The two routes converge on a single wake gate
    /// so the rest of the code path doesn't care how the bundle
    /// got there.
    private func isWebBearing(_ bundleID: String) -> Bool {
        Self.isChromiumBundle(bundleID)
            || discoveredWebBundles.contains(bundleID)
    }

    /// Role allow-list for regional hint mode (issue #34). Large
    /// containers users typically want to *select* rather than
    /// *click* — article bodies, sidebars, split panes, scrollable
    /// outlines, embedded images. Single set, applied identically
    /// inside and outside `AXWebArea` (the same role tokens land in
    /// both: macOS AX surfaces HTML `<article>` / `<section>` /
    /// `<aside>` as the same `AXGroup`-family roles).
    static let regionalRoles: Set<String> = [
        "Group",
        "Article",
        "Section",
        "SplitGroup",
        "ScrollArea",
        "Outline",
        "Image",
    ]

    /// Drop elements whose top-left corner is within `proximityPx`
    /// of another already-kept element's top-left. Keeps the
    /// FIRST one encountered (depth-first, ancestors before
    /// descendants), which is usually the most "container-like"
    /// match — and either container or leaf is a fine click target
    /// since they fire the same AX action.
    private func dedupNearOverlaps(_ elements: [UIElement]) -> [UIElement] {
        var kept: [UIElement] = []
        kept.reserveCapacity(elements.count)
        for e in elements {
            let p = e.frame.origin
            let collides = kept.contains { other in
                abs(other.frame.origin.x - p.x) < proximityPx
                    && abs(other.frame.origin.y - p.y) < proximityPx
            }
            if !collides { kept.append(e) }
        }
        return kept
    }
}

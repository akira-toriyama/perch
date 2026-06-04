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

    /// Pids on which we've already requested AX renderer wake-up
    /// (`AXManualAccessibility = true`). Chrome / Electron expose
    /// nothing under their `AXWebArea` until an AX client signals
    /// interest via this attribute — without it, the page DOM is
    /// invisible to perch (see issue #26 — empty raw dump for
    /// Chrome). Set once per pid, log once, so log scans don't see
    /// the wake line every activation.
    private var wokenPids: Set<pid_t> = []

    /// Pids we've explicitly prewarm-walked at app-activation time.
    /// Chrome's renderer-AX populates asynchronously after the
    /// first query — without prewarm the first hotkey on a freshly-
    /// focused window enumerates only the browser chrome (issue
    /// #28). One-shot per pid; daemon restart resets.
    private var prewarmedPids: Set<pid_t> = []

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
        let pids = wokenPids
        wokenPids.removeAll()
        prewarmedPids.removeAll()
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
        guard Self.isChromiumBundle(bundleID) else { return }
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
        liveById.removeAll(keepingCapacity: true)
        nextSeq = 0

        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier
        else {
            Log.debug("ax: no frontmost app")
            return []
        }
        if excludes.contains(bundleID) {
            Log.debug("ax: excluded app \(bundleID)")
            return []
        }
        Log.debug("ax: front=\(bundleID) pid=\(front.processIdentifier)")

        // Apply per-app overrides for the duration of this enumeration.
        // Resolved from `config` against the now-known frontmost
        // bundleID; missing keys fall through to the global value
        // (preserves the typo-tolerance rule from issue #37). Restored
        // on exit so a subsequent enumerate against a different app
        // doesn't carry over the previous override.
        let savedRoles = self.roles
        let savedMinSize = self.minSize
        let effRoles = config.effectiveRoles(for: bundleID)
        let effMinSize = config.effectiveMinSize(for: bundleID)
        let overridden = (config.perApp[bundleID] != nil)
        if overridden {
            self.roles = Set(effRoles)
            self.minSize = CGFloat(effMinSize)
            Log.debug("ax: per-app override \(bundleID) "
                      + "roles=\(self.roles.count) "
                      + "min-size=\(Int(self.minSize))")
        }
        defer {
            if overridden {
                self.roles = savedRoles
                self.minSize = savedMinSize
            }
        }

        let appElt = AXUIElementCreateApplication(front.processIdentifier)

        // Wake the renderer-accessibility tree on Chromium-based
        // apps (Chrome / Edge / Brave / Arc / VS Code / Slack /
        // Discord / Electron in general). They keep their page /
        // content `AXWebArea` collapsed until an AX client signals
        // interest. Without a wake the raw AX tree for a Chrome
        // window has zero `*WEB*` markers — the page DOM is
        // completely invisible to perch.
        //
        // Two attributes flip the switch:
        //
        //   1. `AXManualAccessibility` — the lighter knob,
        //      preferred when the app supports it. Chrome currently
        //      returns `kAXErrorAttributeUnsupported` (-25205) when
        //      we try to set it on the app element, so this is
        //      kept as best-effort.
        //   2. `AXEnhancedUserInterface` — what VoiceOver flips.
        //      Chromium / Electron honour it. Known to cause
        //      sustained perf hits in Microsoft Office apps (Word
        //      / Excel reroute event handling through assistive
        //      tech APIs while it's on), so we **only** set this
        //      on bundles we recognise as Chromium / Electron.
        //
        // First activation after wake may still see an empty
        // subtree — Chrome populates the renderer AX
        // asynchronously, typically within a few hundred ms. By
        // the second activation the content is there.
        //
        // Logged once per pid so the line doesn't repeat every
        // activation.
        if !wokenPids.contains(front.processIdentifier) {
            let errM = AXUIElementSetAttributeValue(
                appElt,
                "AXManualAccessibility" as CFString,
                kCFBooleanTrue)
            let isChromium = Self.isChromiumBundle(bundleID)
            let errEStr: String
            if isChromium {
                let errE = AXUIElementSetAttributeValue(
                    appElt,
                    "AXEnhancedUserInterface" as CFString,
                    kCFBooleanTrue)
                errEStr = String(errE.rawValue)
            } else {
                errEStr = "skipped"
            }
            wokenPids.insert(front.processIdentifier)
            Log.line("ax: wake → \(bundleID) "
                     + "manual=\(errM.rawValue) "
                     + "enhanced=\(errEStr)")
        }

        guard let focused = copyAttribute(appElt, kAXFocusedWindowAttribute),
              CFGetTypeID(focused as CFTypeRef) == AXUIElementGetTypeID()
        else {
            Log.debug("ax: no focused window for \(bundleID)")
            return []
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
        let axFrame = frameOf(window)
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

        var raw: [UIElement] = []
        let ctx = WalkCtx(maxDepth: nativeMaxDepth, inWebArea: false)
        walk(window, depth: 0, ctx: ctx,
             pid: front.processIdentifier, into: &raw)
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
        Log.line("ax: enumerated \(pruned.count) hint(s) in \(bundleID)")
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

    private func walk(
        _ node: AXUIElement,
        depth: Int,
        ctx: WalkCtx,
        pid: pid_t,
        into out: inout [UIElement]
    ) {
        if depth > ctx.maxDepth { return }

        // Role check — keep it cheap, before reading frame / title.
        let rawRole = (copyAttribute(node, kAXRoleAttribute) as? String) ?? ""
        let role = rawRole.hasPrefix("AX")
            ? String(rawRole.dropFirst(2)) : rawRole

        // Inside a web area the role allow-list comes from
        // `[behavior.web].roles`; outside, from `[behavior].roles`.
        // Same set under default config (webRoles mirrors roles
        // when the user hasn't opted in) — only diverges when the
        // user explicitly tunes web context separately.
        let activeRoles = ctx.inWebArea ? webRoles : roles
        if activeRoles.contains(role),
           let frame = frameOf(node),
           supportsPress(node),
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
                 pid: pid, into: &out)
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
    /// overlay panel).
    private func frameOf(_ node: AXUIElement) -> CGRect? {
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
        // Skip elements smaller than the configured floor on either
        // axis. Default 6 matches the historical "skip 1×1 hidden
        // anchors" floor; raise it (e.g. 20) to declutter icon-only
        // toolbars on dense web pages.
        if s.width < minSize || s.height < minSize { return nil }
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

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
import AVFoundation
import CoreGraphics
import Foundation
import PerchCore
import Vision

public final class AXUIElementSource: UIElementSource, @unchecked Sendable {

    // Whole config snapshot. Used as the source-of-truth for both
    // the global `[behavior]` knobs (via `config.behavior.roles` / `config.behavior.webRoles`
    // / `config.behavior.minSize` / `config.behavior.excludeApps`) and per-app override
    // resolution at enumerate-time (`config.effectiveX(for:)`).
    //
    // Held as a single value rather than destructured Sets so updateConfig
    // is one assignment, and so consumers don't drift from the live config
    // between reloads. The walker reads via `WalkPolicy` snapshots built
    // fresh per enumeration — no instance state is mutated mid-walk.
    private var config: PerchConfig

    // (id → live AXUIElement) — only valid for the most recent
    // enumeration. Re-cleared at the top of every `enumerate()`.
    private var liveById: [String: AXUIElement] = [:]

    // Per-enumeration label override consulted by `act(id:as:)` for
    // `.copyTitle` (#54). `enumerateWindows()` populates this with
    // the composed "<App> — <Window Title>" so the copy lands the
    // string the user actually saw in the picker, not just the raw
    // window title. Other enumerators don't populate it, falling
    // back to the live `kAXTitleAttribute` read.
    private var customLabelById: [String: String] = [:]

    /// `AVSpeechSynthesizer` is held as an instance property because
    /// it owns its in-flight utterance lifetime — a local in
    /// `dispatchSpeak(...)` would deallocate before the audio
    /// playback completed. One instance is fine; consecutive
    /// `.speakTitle` calls queue utterances on the same synth.
    private lazy var speechSynth = AVSpeechSynthesizer()

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
    }

    public func updateConfig(_ cfg: PerchConfig) {
        self.config = cfg
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
        // `effectiveX(for:)` (typo-tolerance preserved). The policy
        // IS the resolved state for this enumeration; no instance
        // state is mutated mid-walk.
        let effRoles = config.behavior.effectiveRoles(for: root.bundleID)
        let effMinSize = CGFloat(
            config.behavior.effectiveMinSize(for: root.bundleID))
        if config.behavior.perApp[root.bundleID] != nil {
            Log.debug("ax: per-app override \(root.bundleID) "
                      + "roles=\(effRoles.count) "
                      + "min-size=\(Int(effMinSize))")
        }
        let policy = WalkPolicy(
            nativeRoles: Set(effRoles),
            webRoles: Set(config.behavior.webRoles),
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
            minWidth: CGFloat(config.regional.minWidth),
            minHeight: CGFloat(config.regional.minHeight),
            requirePress: false)
        return runWalk(window: root.window, policy: policy,
                       label: "region", bundleID: root.bundleID,
                       pid: root.pid)
    }

    /// Issue #52 — menu-bar search. Walks the frontmost app's
    /// `kAXMenuBarAttribute` recursively, collecting every pressable
    /// leaf `AXMenuItem` with a non-empty title. Each emitted
    /// `UIElement` carries:
    ///
    ///   - `label`: the menu path joined by `" > "`
    ///     (e.g. `"File > Save As…"`). The visible bar item is the
    ///     first segment; nested submenus add segments.
    ///   - `frame`: `.zero` — closed menu items have no positioned
    ///     frame. Consumers must render menu results as a list, NOT
    ///     pinned to a frame.
    ///   - `id`: the same `"<pid>:<seq>"` shape `enumerate()` uses,
    ///     stored in the same `liveById` side-table so
    ///     `act(id:as:)` resolves it identically (AXPress fires the
    ///     menu item).
    ///
    /// Separators (`AXMenuItem` with empty title) are skipped.
    /// Disabled items are kept — the user might still want to see
    /// them under the search results.
    public func enumerateMenu() -> [UIElement] {
        liveById.removeAll(keepingCapacity: true)
        customLabelById.removeAll(keepingCapacity: true)
        nextSeq = 0

        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier
        else {
            Log.debug("ax: no frontmost app")
            return []
        }
        if config.behavior.excludeApps.contains(bundleID) {
            Log.debug("ax: excluded app \(bundleID)")
            return []
        }
        self.lastEnumeratedBundleID = bundleID
        Log.debug("ax: menu-walk front=\(bundleID) "
                  + "pid=\(front.processIdentifier)")

        let appElt = AXUIElementCreateApplication(front.processIdentifier)
        guard let menuBarAny = copyAttribute(appElt, kAXMenuBarAttribute),
              CFGetTypeID(menuBarAny as CFTypeRef) == AXUIElementGetTypeID()
        else {
            Log.debug("ax: no menu bar for \(bundleID)")
            return []
        }
        let menuBar = menuBarAny as! AXUIElement

        var out: [UIElement] = []
        walkMenu(menuBar, pathPrefix: "", depth: 0,
                 pid: front.processIdentifier, into: &out)
        Log.line("ax: enumerated \(out.count) menu-item(s) "
                 + "in \(bundleID)")
        return out
    }

    /// Recursive descent into the menu tree. The walker concatenates
    /// titles into a `>`-joined path so downstream search has the
    /// full breadcrumb to match against (`File > Save As…` rather
    /// than just `Save As…`, which would collide across apps).
    ///
    /// Depth ceiling 8 — even Photoshop's nested filter sub-menus
    /// don't reach that.
    private func walkMenu(
        _ node: AXUIElement,
        pathPrefix: String,
        depth: Int,
        pid: pid_t,
        into out: inout [UIElement]
    ) {
        if depth > 8 { return }
        let rawRole = (copyAttribute(node, kAXRoleAttribute) as? String) ?? ""
        let role = rawRole.hasPrefix("AX")
            ? String(rawRole.dropFirst(2)) : rawRole
        let title = (copyAttribute(node, kAXTitleAttribute) as? String) ?? ""

        let path: String
        if !title.isEmpty {
            path = pathPrefix.isEmpty
                ? title
                : "\(pathPrefix) > \(title)"
        } else {
            path = pathPrefix
        }

        // Emit pressable leaves with non-empty title. AXMenu wraps
        // a submenu; AXMenuBar / AXMenuBarItem are containers; only
        // AXMenuItem actually fires. Skipping titleless items rules
        // out separators and the rare anonymous container.
        if role == "MenuItem", !title.isEmpty, supportsPress(node) {
            nextSeq += 1
            let id = "\(pid):\(nextSeq)"
            liveById[id] = node
            let shortcut = readMenuShortcut(node)
            out.append(UIElement(
                id: id, role: role, label: path,
                frame: .zero, shortcut: shortcut))
        }

        let kids = (copyAttribute(node, kAXChildrenAttribute)
                    as? [AXUIElement]) ?? []
        for child in kids {
            walkMenu(child, pathPrefix: path,
                     depth: depth + 1, pid: pid, into: &out)
        }
    }

    /// Issue #54 — cross-app window switcher. Walks every running
    /// `NSRunningApplication.activationPolicy == .regular` app
    /// (skipping faceless background tools that have no user-
    /// switchable windows) and emits one `UIElement` per AX window:
    ///
    ///   - `role`: `"Window"` — `act(id:as:)` uses this as its
    ///     signal to dispatch `kAXRaiseAction` + activate the
    ///     owning app, NOT the normal `kAXPressAction`.
    ///   - `label`: `"<App> — <Window Title>"`, with `" (min)"`
    ///     appended for minimised windows so the user can see at a
    ///     glance which picks won't already be on-screen.
    ///   - `frame`: `.zero` — windows ship to a vertical-list
    ///     render (same render path as `--menu`), not a pill pinned
    ///     to a frame.
    ///   - `id`: the same `"<pid>:<seq>"` shape every other enumerator
    ///     uses, stored in `liveById` so dispatch resolves it back to
    ///     the live `AXUIElement`.
    ///
    /// Apps the user has blocklisted via `[exclude].apps`
    /// are skipped — the same opt-out covers hint mode + window
    /// switcher with no extra knobs.
    public func enumerateWindows() -> [UIElement] {
        liveById.removeAll(keepingCapacity: true)
        customLabelById.removeAll(keepingCapacity: true)
        nextSeq = 0

        var out: [UIElement] = []
        let apps = NSWorkspace.shared.runningApplications
        for app in apps {
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier
            else { continue }
            if config.behavior.excludeApps.contains(bundleID) { continue }
            let pid = app.processIdentifier
            let appName = app.localizedName ?? bundleID

            let appElt = AXUIElementCreateApplication(pid)
            guard let windowsAny = copyAttribute(
                appElt, kAXWindowsAttribute) as? [AXUIElement]
            else { continue }

            for window in windowsAny {
                let title = (copyAttribute(window, kAXTitleAttribute)
                             as? String) ?? ""
                let minimised = (copyAttribute(
                    window, kAXMinimizedAttribute) as? Bool) ?? false
                // Honour AX's "this is a real window the user can
                // interact with" hints. Sheets / panels attached to
                // a parent window report `AXSubrole == "AXDialog"`
                // etc. — we'd surface them as duplicates if we
                // didn't gate on the standard-window subrole. But
                // we don't filter on subrole here because dialogs
                // ARE user-switchable; we just dedupe later.
                let visibleTitle = title.isEmpty ? "(untitled)" : title
                let suffix = minimised ? " (min)" : ""
                let label = "\(appName) — \(visibleTitle)\(suffix)"

                nextSeq += 1
                let id = "\(pid):\(nextSeq)"
                liveById[id] = window
                customLabelById[id] = label
                out.append(UIElement(
                    id: id, role: "Window", label: label, frame: .zero))
            }
        }
        Log.line("ax: enumerated \(out.count) window(s) "
                 + "across \(apps.count) running app(s)")
        return out
    }

    /// Issue #55 — emoji picker. Returns one `UIElement` per
    /// curated `EmojiTable.Entry`:
    ///
    ///   - `role`: `"Emoji"` — the dispatch path (`act(id:as:)`)
    ///     keys off the `"emoji:"` id prefix instead, but the
    ///     role tag keeps the wire shape consistent.
    ///   - `label`: the entry's `keywords` (CLDR name +
    ///     synonyms), space-joined. `SearchFilter.rank(...)` does
    ///     the fuzzy match — "thinking" finds 🤔, "good" finds
    ///     👍, etc.
    ///   - `frame`: `.zero` — emoji ship to the vertical-list
    ///     render (same path as `--menu` and `--windows`); no
    ///     on-screen frame to pin a pill to.
    ///   - `id`: `"emoji:<glyph>"` — the glyph encoded directly
    ///     so dispatch can decode without a side-table lookup.
    ///     No `AXUIElement` exists for an emoji; there's nothing
    ///     to keep in `liveById`.
    ///
    /// `liveById` / `customLabelById` are cleared at the top so a
    /// stale id from a prior enumeration can't resolve.
    public func enumerateEmoji() -> [UIElement] {
        liveById.removeAll(keepingCapacity: true)
        customLabelById.removeAll(keepingCapacity: true)
        nextSeq = 0

        let out: [UIElement] = EmojiTable.entries.map { e in
            UIElement(
                id: "emoji:\(e.glyph)",
                role: "Emoji",
                label: "\(e.glyph) \(e.keywords)",
                frame: .zero)
        }
        Log.line("ax: enumerated \(out.count) emoji entries")
        return out
    }

    /// Issue #73 (M5) — OCR / Vision-based hint enumerator. The
    /// final AX-bypass layer: when even grid isn't enough because
    /// the user wants the **specific text region** they're looking
    /// at (Figma layer name, web `<canvas>` label, image text),
    /// Vision.framework's `VNRecognizeTextRequest` runs OCR on the
    /// main display capture and emits one `UIElement` per
    /// recognized region.
    ///
    /// Coords pipeline (the easy one to get wrong):
    ///   1. `CGDisplayCreateImage(mainDisplay)` → image in PIXEL
    ///      coords (3840×2160 on a 4K @ 2x backing scale).
    ///   2. Vision returns observation `boundingBox` in NORMALISED
    ///      bottom-left origin (0..1 in each axis, y-up).
    ///   3. Multiply by image pixel size, flip Y so the box is
    ///      top-left origin.
    ///   4. Divide by `screen.backingScaleFactor` to land in CG
    ///      global POINT coords (the same space OverlayWindow
    ///      paints in and `CGEvent.mouseEvent` clicks in).
    /// Dropping any of these conversions makes pills land in the
    /// wrong place.
    ///
    /// Each result's id encodes the click centroid directly —
    /// `"vision:<x>:<y>"` in CG global point coords. Dispatch
    /// decodes the id and clicks without a side-table lookup;
    /// the same pattern emoji uses (#55).
    ///
    /// **Screen Recording TCC grant** is required on first call.
    /// `CGDisplayCreateImage` returns nil without the grant —
    /// we log + return empty so the controller can dismiss the
    /// overlay silently rather than crashing.
    ///
    /// **Latency**: `.fast` recognition level ranges 100-400ms
    /// on Apple Silicon for a typical 4K screen. That's slow vs
    /// the AX walk (<30ms) but acceptable for the fallback use
    /// case the user invoked explicitly via `--vision`.
    public func enumerateVision() -> [UIElement] {
        liveById.removeAll(keepingCapacity: true)
        customLabelById.removeAll(keepingCapacity: true)
        nextSeq = 0

        guard let screen = NSScreen.main else {
            Log.line("vision: no main screen")
            return []
        }
        let displayID = CGMainDisplayID()
        guard let image = CGDisplayCreateImage(displayID) else {
            Log.line("vision: CGDisplayCreateImage failed — "
                     + "Screen Recording grant likely missing "
                     + "(System Settings → Privacy & Security → "
                     + "Screen Recording → enable perch)")
            return []
        }

        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .fast
        let handler = VNImageRequestHandler(
            cgImage: image, options: [:])
        do {
            try handler.perform([req])
        } catch {
            Log.line("vision: handler.perform failed (\(error))")
            return []
        }
        guard let observations = req.results else { return [] }

        let imageW = CGFloat(image.width)
        let imageH = CGFloat(image.height)
        let scale = screen.backingScaleFactor

        var out: [UIElement] = []
        for obs in observations {
            guard let top = obs.topCandidates(1).first else { continue }
            let text = top.string.trimmingCharacters(
                in: .whitespacesAndNewlines)
            if text.isEmpty { continue }

            // boundingBox: bottom-left origin, 0..1 normalized.
            let bb = obs.boundingBox
            let pxX = bb.minX * imageW
            let pxYBottomUp = bb.minY * imageH
            let pxW = bb.width * imageW
            let pxH = bb.height * imageH
            // Flip Y to top-left origin in pixel space.
            let pxYTopDown = imageH - (pxYBottomUp + pxH)

            // Pixel → point (CG global, point-space) via the
            // backing-scale divide.
            let frame = CGRect(
                x: pxX / scale, y: pxYTopDown / scale,
                width: pxW / scale, height: pxH / scale)
            let cx = Int(frame.midX)
            let cy = Int(frame.midY)

            nextSeq += 1
            let id = "vision:\(cx):\(cy)"
            out.append(UIElement(
                id: id, role: "VisionText",
                label: text, frame: frame))
        }
        Log.line("vision: \(out.count) text region(s)")
        return out
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
        customLabelById.removeAll(keepingCapacity: true)
        nextSeq = 0

        guard let front = NSWorkspace.shared.frontmostApplication,
              let bundleID = front.bundleIdentifier
        else {
            Log.debug("ax: no frontmost app")
            return nil
        }
        if config.behavior.excludeApps.contains(bundleID) {
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
        // Emoji dispatch (#55): id encodes the glyph itself; no
        // AXUIElement side-table entry — the action is a Unicode
        // CGEvent that types the glyph at the caret. Short-circuit
        // before the `liveById` guard since the table never holds
        // emoji rows.
        if let glyph = emojiGlyph(fromId: id) {
            return dispatchEmoji(glyph, action: action, id: id)
        }
        // Vision dispatch (#73 / M5): id encodes the click
        // centroid in CG global coords. Same "no liveById entry"
        // shape as emoji.
        if let pt = visionPoint(fromId: id) {
            return dispatchVisionClick(at: pt, action: action,
                                       id: id)
        }
        guard let elt = liveById[id] else {
            Log.line("dispatch: no live element for id=\(id)")
            return false
        }
        switch action {
        case .press, .pressContinuous:
            // Window-switcher case (#54): `.press` against a window
            // means "raise this window AND bring its app to the
            // front", not "fire the window's press action". AX
            // distinguishes them — `kAXPressAction` on a window
            // typically does nothing — so route through
            // `raiseWindow(_:id:)` whenever the role says `Window`.
            // `.pressContinuous` is the same dispatch with the
            // Controller re-entering the picker afterwards (chain
            // multiple window raises in a row), so it shares this
            // branch.
            if isWindowRole(elt) {
                return raiseWindow(elt, id: id)
            }
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
            // Composed label override takes priority — the window
            // switcher (#54) caches `"<App> — <Title>"` here so
            // copyTitle lands the string the user actually saw in
            // the picker, not just the raw window title.
            let title: String
            if let cached = customLabelById[id], !cached.isEmpty {
                title = cached
            } else {
                title = (copyAttribute(elt, kAXTitleAttribute) as? String)
                    ?? (copyAttribute(elt, kAXValueAttribute) as? String)
                    ?? ""
            }
            guard !title.isEmpty else {
                Log.line("dispatch: copyTitle empty → id=\(id)")
                return false
            }
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(title, forType: .string)
            Log.line("dispatch: copyTitle ok (\(title.count) chars) → id=\(id)")
            return true
        case .copyURL:
            // Chord `,u` (#57). `kAXURLAttribute` is the
            // canonical AX surface for "this element has an
            // associated URL" — Safari links, Finder file
            // selections, Mail attachment rows, etc. The value
            // comes back as either NSURL or NSString depending
            // on the app; handle both.
            return dispatchCopyURL(elt, id: id)
        case .revealInFinder:
            // Chord `,o` (#57). Reveal the element's file URL in
            // Finder via `activateFileViewerSelecting`. Only
            // meaningful when `kAXURLAttribute` is a file:// URL;
            // other URL schemes log + return false rather than
            // open in a browser (that's `kAXPressAction`'s job).
            return dispatchRevealInFinder(elt, id: id)
        case .synthCmdClick:
            return dispatchSynthClick(elt, flags: .maskCommand,
                                      id: id, tag: "synth-cmd-click")
        case .synthShiftClick:
            return dispatchSynthClick(elt, flags: .maskShift,
                                      id: id, tag: "synth-shift-click")
        case .doubleClick:
            return dispatchMultiClick(elt, count: 2,
                                      id: id, tag: "double-click")
        case .tripleClick:
            return dispatchMultiClick(elt, count: 3,
                                      id: id, tag: "triple-click")
        case .nestedGrid:
            // M5+ (#74) — Controller-level routing. The chord
            // arrives here so the switch stays exhaustive, but
            // the actual grid entry is wired in
            // `Controller.runHintFlow`'s onResolve (where it has
            // access to `enterNestedGridMode`). Return true so
            // the dispatch log records a clean "ok" rather than
            // the no-live-element fallback. AXUIElementSource
            // doesn't own GridMode — that's a Controller resource.
            Log.line("dispatch: nestedGrid (Controller routes) → id=\(id)")
            return true
        case .speakTitle:
            // Chord `,s` (#57). Speak the element's title /
            // composed label via AVSpeechSynthesizer. Same label
            // resolution rule as `.copyTitle` — picker-composed
            // strings win when present.
            let phrase: String
            if let cached = customLabelById[id], !cached.isEmpty {
                phrase = cached
            } else {
                phrase = (copyAttribute(elt, kAXTitleAttribute) as? String)
                    ?? (copyAttribute(elt, kAXValueAttribute) as? String)
                    ?? ""
            }
            guard !phrase.isEmpty else {
                Log.line("dispatch: speakTitle empty → id=\(id)")
                return false
            }
            let utt = AVSpeechUtterance(string: phrase)
            utt.voice = AVSpeechSynthesisVoice(language: nil)
            speechSynth.speak(utt)
            Log.line("dispatch: speakTitle ok "
                     + "(\(phrase.count) chars) → id=\(id)")
            return true
        }
    }

    /// `.copyURL` body — extracted to keep the `act(...)` switch
    /// readable. `kAXURLAttribute` returns NSURL on most apps,
    /// NSString on a few; handle both, dropping nil / empty values
    /// loudly so the chord doesn't silently no-op.
    private func dispatchCopyURL(
        _ elt: AXUIElement, id: String
    ) -> Bool {
        let raw = copyAttribute(elt, kAXURLAttribute)
        let urlStr: String?
        if let url = raw as? URL {
            urlStr = url.absoluteString
        } else if let s = raw as? String {
            urlStr = s
        } else {
            urlStr = nil
        }
        guard let s = urlStr, !s.isEmpty else {
            Log.line("dispatch: copyURL no kAXURLAttribute → id=\(id)")
            return false
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        Log.line("dispatch: copyURL ok (\(s.count) chars) → id=\(id)")
        return true
    }

    /// Issue #70 / M4-ε — synthetic modifier-held mouse click at
    /// the element's frame center. AX dispatch (`kAXPressAction`)
    /// doesn't honor modifier flags, so "Cmd-click to open in
    /// new tab" / "Shift-click to extend selection" are
    /// unreachable through the regular hint path. This route
    /// uses `CGEvent` with `.flags = mod` to mimic a real
    /// modifier-held click.
    ///
    /// **Crosses the AX-bypass carve-out** (cursor visibly jumps
    /// to the element). Same rationale as `--grid` / `--drag` /
    /// `--nudge`: when AX-press can't deliver the semantic, mouse
    /// synth is the only option.
    private func dispatchSynthClick(
        _ elt: AXUIElement, flags: CGEventFlags,
        id: String, tag: String
    ) -> Bool {
        // Resolve the element's frame center. Use the raw AX
        // position+size — `enumerate()` already filtered out
        // off-screen / clipped elements, so this is the visible
        // bounds we computed when emitting the hint.
        let center = frameCenter(of: elt)
        guard let pt = center else {
            Log.line("dispatch: \(tag) no frame → id=\(id)")
            return false
        }
        _ = CGWarpMouseCursorPosition(pt)
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                mouseEventSource: src,
                mouseType: .leftMouseDown,
                mouseCursorPosition: pt,
                mouseButton: .left),
              let up = CGEvent(
                mouseEventSource: src,
                mouseType: .leftMouseUp,
                mouseCursorPosition: pt,
                mouseButton: .left)
        else {
            Log.line("dispatch: \(tag) CGEvent create failed "
                     + "→ id=\(id)")
            return false
        }
        // Modifier flags attach to BOTH events. Most apps key off
        // the down event but a few (Safari new-tab handling among
        // them) read flags off the up event too — set on both to
        // be safe.
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Log.line("dispatch: \(tag) ok @ "
                 + "(\(Int(pt.x)),\(Int(pt.y))) → id=\(id)")
        return true
    }

    /// Issue #72 / M4-η — synthetic multi-click (double / triple)
    /// at the element's frame center. AX has no "double-click"
    /// action and AXPress fires once; this is the only path to
    /// word- / line-select semantics from hint mode.
    ///
    /// macOS reads multi-click via `kCGMouseEventClickState` on
    /// each event in the sequence (1, 2, 3, …). Posting two
    /// mouseDown+mouseUp pairs with clickState 1 then 2 is what
    /// makes the receiving app's `-[NSEvent clickCount]` read 2.
    /// All events go through `cghidEventTap` rapid-fire — macOS's
    /// double-click threshold (typically 500ms) is comfortable
    /// for synchronous `.post(...)` calls.
    private func dispatchMultiClick(
        _ elt: AXUIElement, count: Int,
        id: String, tag: String
    ) -> Bool {
        guard count >= 1, let pt = frameCenter(of: elt) else {
            Log.line("dispatch: \(tag) no frame → id=\(id)")
            return false
        }
        _ = CGWarpMouseCursorPosition(pt)
        guard let src = CGEventSource(stateID: .hidSystemState) else {
            Log.line("dispatch: \(tag) no event source → id=\(id)")
            return false
        }
        for i in 1...count {
            guard let down = CGEvent(
                mouseEventSource: src,
                mouseType: .leftMouseDown,
                mouseCursorPosition: pt,
                mouseButton: .left),
                  let up = CGEvent(
                    mouseEventSource: src,
                    mouseType: .leftMouseUp,
                    mouseCursorPosition: pt,
                    mouseButton: .left)
            else { continue }
            down.setIntegerValueField(.mouseEventClickState,
                                      value: Int64(i))
            up.setIntegerValueField(.mouseEventClickState,
                                    value: Int64(i))
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
        }
        Log.line("dispatch: \(tag) ok @ "
                 + "(\(Int(pt.x)),\(Int(pt.y))) → id=\(id)")
        return true
    }

    /// Read `(kAXPosition, kAXSize)` and return the frame's
    /// center in CG global coords. Used by synthetic-click
    /// dispatch (#70) which needs the click point but doesn't
    /// have a `UIElement.frame` handy (the dispatch path receives
    /// only the live `AXUIElement`, not the original `UIElement`
    /// that ferried the frame to Core).
    private func frameCenter(of elt: AXUIElement) -> CGPoint? {
        var posVal: CFTypeRef?
        var sizeVal: CFTypeRef?
        let errP = AXUIElementCopyAttributeValue(
            elt, kAXPositionAttribute as CFString, &posVal)
        let errS = AXUIElementCopyAttributeValue(
            elt, kAXSizeAttribute as CFString, &sizeVal)
        guard errP == .success, errS == .success,
              let pRef = posVal, let sRef = sizeVal,
              CFGetTypeID(pRef) == AXValueGetTypeID(),
              CFGetTypeID(sRef) == AXValueGetTypeID()
        else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        _ = AXValueGetValue(pRef as! AXValue, .cgPoint, &pos)
        _ = AXValueGetValue(sRef as! AXValue, .cgSize, &size)
        return CGPoint(x: pos.x + size.width / 2,
                       y: pos.y + size.height / 2)
    }

    /// `.revealInFinder` body — only fires on `file://` URLs.
    /// Other schemes (`https://` links etc.) log + return false
    /// rather than open in a browser (`.press` already does that).
    private func dispatchRevealInFinder(
        _ elt: AXUIElement, id: String
    ) -> Bool {
        let raw = copyAttribute(elt, kAXURLAttribute)
        let url: URL?
        if let u = raw as? URL {
            url = u
        } else if let s = raw as? String {
            url = URL(string: s)
        } else {
            url = nil
        }
        guard let u = url, u.isFileURL else {
            Log.line("dispatch: revealInFinder no file URL → id=\(id)")
            return false
        }
        NSWorkspace.shared.activateFileViewerSelecting([u])
        Log.line("dispatch: revealInFinder ok → \(u.path)")
        return true
    }

    /// Raise `window` + bring its owning app to the front. The id
    /// of the form `"<pid>:<seq>"` is the source of the pid; we
    /// resolve the `NSRunningApplication` from it rather than re-
    /// querying NSWorkspace (which would race with focus changes
    /// since `enumerateWindows()` returned).
    private func raiseWindow(
        _ window: AXUIElement, id: String
    ) -> Bool {
        let raiseErr = AXUIElementPerformAction(
            window, kAXRaiseAction as CFString)
        let pidPart = id.split(separator: ":").first.map(String.init) ?? ""
        let pid = pid_t(pidPart) ?? 0
        var activated = false
        if pid != 0, let app = NSRunningApplication(processIdentifier: pid) {
            if #available(macOS 14.0, *) {
                activated = app.activate()
            } else {
                activated = app.activate(options: [.activateIgnoringOtherApps])
            }
        }
        let ok = raiseErr == .success
        Log.line("dispatch: AXRaise " + (ok ? "ok" : "failed")
                 + " (\(raiseErr.rawValue)) activate=\(activated) "
                 + "→ id=\(id)")
        return ok
    }

    /// Is `elt`'s AX role `kAXWindowRole`? Read at dispatch time
    /// (cheap one-call AX query) rather than caching per-id role —
    /// only the window switcher (#54) needs this distinction and
    /// the side-table for it would touch every enumerator.
    private func isWindowRole(_ elt: AXUIElement) -> Bool {
        guard let role = copyAttribute(elt, kAXRoleAttribute) as? String
        else { return false }
        return role == kAXWindowRole as String
    }

    /// Read the AX-bound shortcut on a menu item (issue #58).
    /// Returns the macOS canonical glyph form (`⌃⌥⇧⌘<key>`) or
    /// `nil` if the item has no character-based shortcut.
    ///
    /// `kAXMenuItemCmdChar` is the trigger character (string,
    /// usually one Unicode scalar). `kAXMenuItemCmdModifiers` is
    /// a Carbon-style bitmask with an unusual convention:
    ///
    ///   bit 0 (1)  →  ⌃ Control
    ///   bit 1 (2)  →  ⌥ Option
    ///   bit 2 (4)  →  ⇧ Shift
    ///   bit 3 (8)  →  **no command** (cmd is implied unless this
    ///                  bit is set)
    ///
    /// So `kAXMenuItemCmdModifiers == 0` means `⌘<char>`, not
    /// "no modifiers". This matches Carbon's `kMenuShiftModifier`
    /// / `kMenuNoCommandModifier` constants documented for
    /// `CGEventCreateKeyboardEvent` & friends.
    ///
    /// Items that bind via `kAXMenuItemCmdVirtualKey` /
    /// `kAXMenuItemCmdGlyph` (function keys, Tab, arrow keys, …)
    /// fall through to `nil` for v1 — the glyph-table mapping is
    /// in scope for a follow-up. Char-bound shortcuts cover the
    /// overwhelming majority of menu commands users reach for.
    private func readMenuShortcut(_ node: AXUIElement) -> String? {
        let char = (copyAttribute(
            node, "AXMenuItemCmdChar") as? String) ?? ""
        guard !char.isEmpty else { return nil }
        let mods = (copyAttribute(
            node, "AXMenuItemCmdModifiers") as? Int) ?? 0
        // Canonical macOS glyph order: ⌃⌥⇧⌘<key>. Cmd is last —
        // appending (not prepending) keeps "⌘⇧N" wrong; "⇧⌘N"
        // right.
        var glyphs = ""
        if mods & 1 != 0 { glyphs += "⌃" }
        if mods & 2 != 0 { glyphs += "⌥" }
        if mods & 4 != 0 { glyphs += "⇧" }
        if mods & 8 == 0 { glyphs += "⌘" }
        return glyphs + char.uppercased()
    }

    /// Emoji picker (#55) id encoding: `"emoji:<glyph>"`. Returns
    /// the glyph if the id matches that shape; nil for everything
    /// else (lets the caller fall through to `liveById`).
    private func emojiGlyph(fromId id: String) -> String? {
        let prefix = "emoji:"
        guard id.hasPrefix(prefix) else { return nil }
        let glyph = String(id.dropFirst(prefix.count))
        return glyph.isEmpty ? nil : glyph
    }

    /// Vision picker (#73 / M5) id encoding: `"vision:<x>:<y>"`.
    /// Returns the click centroid in CG global coords; nil for
    /// any other shape. Parsing fails-closed — anything that
    /// doesn't split cleanly into 3 parts (`vision`, x, y) of
    /// integer x / y returns nil, and the caller falls through.
    private func visionPoint(fromId id: String) -> CGPoint? {
        let parts = id.split(separator: ":", maxSplits: 2,
                             omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "vision",
              let x = Int(parts[1]), let y = Int(parts[2])
        else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// Click at the centroid carried in a `vision:<x>:<y>` id.
    /// Mirrors the action mapping the grid mode uses:
    ///   .press / .pressContinuous  → left click
    ///   .rightClick                → right click
    ///   .copyTitle                 → copy the recognised text
    ///                                 (NOT click — useful "copy
    ///                                 the price I'm looking at"
    ///                                 ergonomic)
    ///   .focus                     → warp only (no click)
    ///   everything else            → unsupported, log + false
    /// `.copyTitle` is the only non-click branch — it needs the
    /// original recognised text. That's stored in the matching
    /// `UIElement.label`, but `act(...)` only receives the id;
    /// so we surface a `customLabelById` entry at enumerate time
    /// when the consumer says it'll need the text post-resolve.
    /// For v1 we don't populate that — `.copyTitle` on a vision
    /// id falls back to logging "no text cached" + returning
    /// false. Real implementation lands when the use case shows up.
    private func dispatchVisionClick(
        at point: CGPoint, action: HintAction, id: String
    ) -> Bool {
        switch action {
        case .press, .pressContinuous:
            return synthClick(at: point, button: .left,
                              flags: [], id: id, tag: "vision-click")
        case .rightClick:
            return synthClick(at: point, button: .right,
                              flags: [], id: id, tag: "vision-right")
        case .focus:
            // "warp only" — useful before --drag picks up.
            _ = CGWarpMouseCursorPosition(point)
            Log.line("dispatch: vision warp-only @ "
                     + "(\(Int(point.x)),\(Int(point.y))) → id=\(id)")
            return true
        case .copyTitle:
            // No cached text for v1 — see doc above.
            Log.line("dispatch: vision copyTitle "
                     + "(no cached text yet) → id=\(id)")
            return false
        case .synthCmdClick:
            return synthClick(at: point, button: .left,
                              flags: .maskCommand,
                              id: id, tag: "vision-cmd-click")
        case .synthShiftClick:
            return synthClick(at: point, button: .left,
                              flags: .maskShift,
                              id: id, tag: "vision-shift-click")
        case .doubleClick:
            return synthMultiClick(at: point, count: 2,
                                   id: id, tag: "vision-double")
        case .tripleClick:
            return synthMultiClick(at: point, count: 3,
                                   id: id, tag: "vision-triple")
        case .revealInFinder, .speakTitle, .copyURL, .nestedGrid:
            // .copyURL not meaningful for OCR text (we don't have
            // a URL attribute, just the recognised string).
            // .revealInFinder / .speakTitle require source data
            // (file URL / spoken text) we don't carry on vision
            // hits. .nestedGrid would be meaningful (OCR boxes
            // can be large) but the Controller routes that case
            // before dispatch reaches here for AX hits — same
            // routing should land in vision flow if needed
            // later; deferred for v1.
            Log.line("dispatch: vision unsupported action "
                     + "\(action.rawValue) → id=\(id)")
            return false
        }
    }

    /// Generalised "synthesise one click at point" used by vision
    /// dispatch. Same pattern as `dispatchSynthClick(...)` (#70)
    /// but parameterised on button + flags + point (rather than
    /// reading the position from an AXUIElement).
    private func synthClick(
        at point: CGPoint, button: CGMouseButton,
        flags: CGEventFlags, id: String, tag: String
    ) -> Bool {
        _ = CGWarpMouseCursorPosition(point)
        let down: CGEventType =
            (button == .right) ? .rightMouseDown : .leftMouseDown
        let up: CGEventType =
            (button == .right) ? .rightMouseUp : .leftMouseUp
        guard let src = CGEventSource(stateID: .hidSystemState),
              let d = CGEvent(
                mouseEventSource: src, mouseType: down,
                mouseCursorPosition: point, mouseButton: button),
              let u = CGEvent(
                mouseEventSource: src, mouseType: up,
                mouseCursorPosition: point, mouseButton: button)
        else {
            Log.line("dispatch: \(tag) CGEvent create failed → id=\(id)")
            return false
        }
        if !flags.isEmpty {
            d.flags = flags
            u.flags = flags
        }
        d.post(tap: .cghidEventTap)
        u.post(tap: .cghidEventTap)
        Log.line("dispatch: \(tag) ok @ "
                 + "(\(Int(point.x)),\(Int(point.y))) → id=\(id)")
        return true
    }

    /// Coord-based multi-click for vision (no AXUIElement). Same
    /// `kCGMouseEventClickState` 1/2/3 sequence as
    /// `dispatchMultiClick(_:count:...)` (#72).
    private func synthMultiClick(
        at point: CGPoint, count: Int,
        id: String, tag: String
    ) -> Bool {
        guard count >= 1 else { return false }
        _ = CGWarpMouseCursorPosition(point)
        guard let src = CGEventSource(stateID: .hidSystemState) else {
            return false
        }
        for i in 1...count {
            guard let d = CGEvent(
                mouseEventSource: src, mouseType: .leftMouseDown,
                mouseCursorPosition: point, mouseButton: .left),
                  let u = CGEvent(
                    mouseEventSource: src, mouseType: .leftMouseUp,
                    mouseCursorPosition: point, mouseButton: .left)
            else { continue }
            d.setIntegerValueField(.mouseEventClickState,
                                   value: Int64(i))
            u.setIntegerValueField(.mouseEventClickState,
                                   value: Int64(i))
            d.post(tap: .cghidEventTap)
            u.post(tap: .cghidEventTap)
        }
        Log.line("dispatch: \(tag) ok @ "
                 + "(\(Int(point.x)),\(Int(point.y))) → id=\(id)")
        return true
    }

    /// Type / copy the emoji glyph. `.press` and `.pressContinuous`
    /// route to `typeUnicodeString(...)` — caret-targeted Unicode
    /// CGEvent that does NOT touch the pasteboard. `.copyTitle`
    /// copies the glyph itself (the user asked for it explicitly).
    /// `.rightClick` / `.focus` aren't meaningful for an emoji and
    /// log + return false rather than no-op silently.
    private func dispatchEmoji(
        _ glyph: String, action: HintAction, id: String
    ) -> Bool {
        switch action {
        case .press, .pressContinuous:
            return typeUnicodeString(glyph, id: id)
        case .copyTitle, .copyURL:
            // Both copy-like actions land on the same pasteboard
            // write for emoji — there's no separate "URL" concept.
            // `.copyURL` arrives via chord `,u`; treat it as copy.
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(glyph, forType: .string)
            Log.line("dispatch: emoji copy → \(id)")
            return true
        case .rightClick, .focus, .revealInFinder, .speakTitle,
             .synthCmdClick, .synthShiftClick,
             .doubleClick, .tripleClick, .nestedGrid:
            Log.line("dispatch: emoji unsupported action "
                     + "\(action.rawValue) → \(id)")
            return false
        }
    }

    /// Inject `s` at the focused field's caret via
    /// `CGEvent.keyboardSetUnicodeString` — pasteboard-clean
    /// (no Cmd+V, no `pb.setString` write). The receiving app
    /// reads the unicode payload off the synthetic keyDown event
    /// as if the user had typed it. Same approach the macOS
    /// built-in emoji picker (Ctrl+Cmd+Space) takes.
    ///
    /// CGEvent's unicode-string buffer caps at 20 UTF-16 units —
    /// fits every emoji in `EmojiTable` (longest ZWJ sequences
    /// are ~11 UTF-16). Truncation here would silently drop
    /// payload; the entries are vetted at definition time so
    /// the cap doesn't trip in practice.
    private func typeUnicodeString(_ s: String, id: String) -> Bool {
        let utf16 = Array(s.utf16)
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                keyboardEventSource: src,
                virtualKey: 0, keyDown: true),
              let up = CGEvent(
                keyboardEventSource: src,
                virtualKey: 0, keyDown: false)
        else {
            Log.line("dispatch: emoji typeUnicode failed "
                     + "(no event source) → \(id)")
            return false
        }
        utf16.withUnsafeBufferPointer { buf in
            down.keyboardSetUnicodeString(
                stringLength: buf.count,
                unicodeString: buf.baseAddress)
            up.keyboardSetUnicodeString(
                stringLength: buf.count,
                unicodeString: buf.baseAddress)
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Log.line("dispatch: emoji typed (\(utf16.count) units) → \(id)")
        return true
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

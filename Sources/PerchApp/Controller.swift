// Orchestrator. Owns the hotkey monitor, AX source, overlay, and
// the live config snapshot. The hotkey trampoline (Carbon callback,
// also `perch --activate` over DNC) lands on `activate()`, which
// runs the full flow:
//   1. source.enumerate()         AX walk in the adapter
//   2. Labeler.assign → hints     pure logic in Core
//   3. overlay.show(hints)        installs KeyTap (CGEventTap),
//                                  paints panel, returns immediately
//                                  — keypresses come back via the
//                                  onResolve / onCancel callbacks
//   4. on resolve →
//      source.act(id:as: action)  dispatches the chosen HintAction
//                                  (press / rightClick / focus /
//                                  copyTitle, picked by which
//                                  modifier was held)
//
// `ScrollMode` and `SearchMode` are parallel orchestrations sharing
// the same single-KeyTap rule: only one mode is up at a time.
// `cancel()` tears down whichever is active.

import AppKit
import CoreGraphics
import Foundation
import PerchCore
import PerchAdapterMacOS

@MainActor
final class Controller {

    /// Which overlay-based mode currently owns the `OverlayWindow`.
    /// `hint` and `regional` share the same overlay + label /
    /// resolution pipeline (`runHintFlow`), so a single enum is
    /// enough to tell them apart for the toggle / switch logic in
    /// `activate()` / `enterRegionalMode()`. `nil` when no
    /// overlay-based mode is up; scroll / search modes have their
    /// own typed nullables (`scroll` / `search`) and are NOT tracked
    /// here.
    enum ActiveMode {
        case hint
        case regional
    }

    private(set) var config: PerchConfig
    private let source: AXUIElementSource
    private let overlay: OverlayWindow
    private let sound: SoundPlayer
    // Created in `start()` because the callback captures `self` — a
    // self-capturing closure can't be passed during the initializer
    // (Swift forbids accessing self before all stored properties are
    // set). Holding it as Optional keeps the type checker happy and
    // matches its lifecycle (only set while the daemon is running).
    private var hotkey: HotkeyMonitor?
    /// Which (if any) overlay-based mode is currently up. `nil`
    /// when the overlay is hidden. Replaces the old `active: Bool`
    /// — distinguishing hint vs regional matters for the toggle
    /// path (`--regional` while regional is up should cancel;
    /// `--regional` while hint is up should switch).
    private var activeMode: ActiveMode?
    /// Set when scroll mode owns the KeyTap. Mutually exclusive
    /// with the overlay-based modes — Controller tears down
    /// whichever is active before starting another.
    private var scroll: ScrollMode?
    /// Set when search mode owns the KeyTap. Mutually exclusive
    /// with the overlay-based modes and scroll.
    private var search: SearchMode?
    /// Set when grid mode (issue #66 / M4-α) owns the KeyTap.
    /// Mutually exclusive with every other mode. Tracked
    /// separately from `search` because the rendering surface
    /// (GridCanvas vs SearchCanvas) and dispatch (CGEvent mouse
    /// vs AX action) diverge enough that conflating them would
    /// mean special-case logic in every teardown path.
    private var grid: GridMode?
    /// Set when nudge mode (issue #68 / M4-γ) owns the KeyTap.
    /// No overlay panel — the cursor is the only visual feedback.
    /// Mutually exclusive with every other mode.
    private var nudge: NudgeMode?
    /// Set when drag mode (issue #69 / M4-δ) owns the KeyTap.
    /// Holds a system-level `leftMouseDown` while active (the
    /// `.dragging` phase) — `cancel()` and the safety paths in
    /// `DragMode.stop()` MUST release before tearing down to
    /// avoid stranding the mouseDown. Mutually exclusive.
    private var drag: DragMode?

    /// File-system watcher on `~/.config/perch/config.toml`. Fires
    /// `reload(cause: "fs")` on save so users don't need to invoke
    /// `perch --reload` after every edit. Created in `start()` so
    /// the callback can capture `self` after stored-property init
    /// completes (same lifecycle as `hotkey`).
    private var configWatcher: ConfigWatcher?

    init(config: PerchConfig) {
        self.config = config
        self.source = AXUIElementSource(config: config)
        self.sound = SoundPlayer(config: config)
        self.overlay = OverlayWindow(config: config, sound: sound)
    }

    func start() {
        // The hotkey callback is @Sendable + nonisolated (Carbon
        // dispatches it from the main thread but Swift 6 sees it as
        // task-isolated). Hop explicitly onto the main actor so the
        // @MainActor-isolated `activate()` is callable.
        let monitor = HotkeyMonitor { [weak self] in
            Task { @MainActor in self?.activate() }
        }
        monitor.install(combo: config.hotkey)
        self.hotkey = monitor
        installControlObserver()
        installAppActivationObserver()
        // Hot-reload: watch the user's config file so saves take
        // effect without a `perch --reload` IPC round-trip. The
        // watcher is a no-op when the file doesn't exist (the
        // built-in defaults are already loaded; user can `perch
        // --reload` after creating it).
        let watcher = ConfigWatcher { [weak self] in
            Task { @MainActor [weak self] in
                self?.reload(cause: "fs")
            }
        }
        _ = watcher.start()
        self.configWatcher = watcher
        // Catch the case where perch starts WHILE a Chromium app is
        // already frontmost — the activation notification only fires
        // on subsequent switches, so we'd miss the very first one.
        if let front = NSWorkspace.shared.frontmostApplication,
           let bid = front.bundleIdentifier {
            source.prewarm(pid: front.processIdentifier, bundleID: bid)
        }
        writeStatus(reason: "start")
        Log.line("controller: started")
    }

    func reload(cause: String) {
        Log.line("config: reloading (\(cause))")
        let new = PerchConfig.load()
        let hotkeyChanged = new.hotkey != config.hotkey
        config = new
        source.updateConfig(new)
        overlay.updateConfig(new)
        sound.updateConfig(new)
        if hotkeyChanged {
            hotkey?.install(combo: new.hotkey)
        }
        writeStatus(reason: "reload")
    }

    // MARK: - Hot flow

    /// Programmatic cancel — used by the `--cancel` IPC command.
    /// Tears down whichever mode owns the KeyTap (hint / regional
    /// / scroll / search). Idempotent; no-op when nothing is active.
    func cancel() {
        if activeMode != nil {
            overlay.hide()
            activeMode = nil
        }
        if let s = scroll {
            s.stop()
            scroll = nil
        }
        if let s = search {
            s.stop()
            search = nil
        }
        if let g = grid {
            g.stop()
            grid = nil
        }
        if let n = nudge {
            n.stop()
            nudge = nil
        }
        if let d = drag {
            d.stop()
            drag = nil
        }
    }

    /// Enter scroll mode. Mutually exclusive with every other mode.
    /// **Toggle semantics**: invoking `--scroll` while scroll mode
    /// is already up cancels (matches CLAUDE.md's "second invocation
    /// while the mode is up cancels — same path as `--cancel`"
    /// guarantee). The pre-cleanup is necessary so a transition
    /// like `--scroll` while hint mode is up tears hint down and
    /// then starts scroll — no toggle in that case.
    func enterScrollMode() {
        if scroll != nil {
            cancel()
            return
        }
        cancel()                            // tear down any other mode
        let sm = ScrollMode(cancelKey: config.cancelKey) { [weak self] in
            Task { @MainActor [weak self] in self?.scroll = nil }
        }
        if sm.start() {
            scroll = sm
            writeStatus(reason: "scroll mode")
        }
    }

    /// Enter search mode. Same mutual-exclusion + toggle rules as
    /// scroll mode. Resolves to a `(UIElement, HintAction)` tuple
    /// just like hint mode so the dispatch path is shared.
    func enterSearchMode() {
        if search != nil {
            cancel()
            return
        }
        startSearchSession(
            renderMode: .pillsOverElements,
            enumerator: { $0.enumerate() },
            statusReason: "search",
            reenter: { [weak self] in self?.enterSearchMode() })
    }

    /// Menu-bar search (issue #52) — reuses `SearchMode`'s query
    /// pipeline against `source.enumerateMenu()` and renders matches
    /// as a centred vertical list (menu items have no on-screen
    /// frame, so the per-pill placement of `--search` doesn't
    /// apply). Same mutual-exclusion + toggle semantics as
    /// `--search`. `.pressContinuous` re-enters menu mode so the
    /// user can chain menu commands.
    func enterMenuMode() {
        if search != nil {
            cancel()
            return
        }
        startSearchSession(
            renderMode: .verticalList,
            enumerator: { $0.enumerateMenu() },
            statusReason: "menu",
            reenter: { [weak self] in self?.enterMenuMode() })
    }

    /// Cross-app window switcher (issue #54) — enumerates every
    /// window across every running app, surfaces matches as a
    /// `.verticalList` (same render as `--menu` since windows
    /// have no useful on-screen frame for the picker), and on
    /// resolve dispatches `kAXRaiseAction` + `NSRunningApplication.
    /// activate(...)` (handled adapter-side in `act(id:as:)` when
    /// the element role is `Window`). `.pressContinuous` re-enters
    /// the picker so the user can raise several windows in a row.
    /// Same mutual-exclusion + toggle semantics as the other
    /// SearchMode-driven flows.
    func enterWindowMode() {
        if search != nil {
            cancel()
            return
        }
        startSearchSession(
            renderMode: .verticalList,
            enumerator: { $0.enumerateWindows() },
            statusReason: "windows",
            reenter: { [weak self] in self?.enterWindowMode() })
    }

    /// Coordinate grid (issue #66 / M4-α) — the explicit AX-bypass
    /// fallback for Figma canvas / Photoshop / web `<canvas>` and
    /// other UIs where hint mode can't see the target. Divides the
    /// screen union into `[grid].cols × [grid].rows` cells, labels
    /// each via `Labeler.assign(...)`, and warps the cursor +
    /// synthesises a `CGEvent` mouse click on resolve. Modifier-
    /// driven action mapping: bare → left click, Shift → right,
    /// Cmd → warp only, Cmd+Shift → click + re-enter for chained
    /// operations. Mutually exclusive with every other mode.
    func enterGridMode() {
        startGridSession(maxDepth: 1, statusReason: "grid",
                         reenter: { [weak self] in self?.enterGridMode() })
    }

    /// Bridge from hint-mode `.nestedGrid` chord to GridMode
    /// scoped to the picked element's frame. Small elements
    /// (`frame.size < [grid].nest-min-size` on either axis) fall
    /// back to AXPress — subdividing a button-sized element with
    /// another grid is meaningless.
    private func enterNestedGridFor(hint: Hint) {
        let f = hint.element.frame
        let threshold = CGFloat(config.gridNestMinSize)
        if f.width < threshold || f.height < threshold {
            Log.line("controller: nestedGrid → too small "
                     + "(\(Int(f.width))×\(Int(f.height))) "
                     + "→ AXPress fallback")
            _ = source.act(id: hint.element.id, as: .press)
            return
        }
        cancel()
        let gm = GridMode(
            config: config,
            maxDepth: config.gridMaxDepth,
            initialFrame: f,
            onExit: { [weak self] in
                Task { @MainActor [weak self] in self?.grid = nil }
            },
            onReenter: { [weak self] in
                // Re-entry on .pressContinuous would re-open the
                // nested grid with the SAME picked frame. Plausible
                // workflow ("click 5 spots inside this textarea")
                // but adds the requirement to carry `f` across the
                // re-entry callback. Deferred — re-entry just falls
                // through to the standard rgrid scope.
                self?.enterRecursiveGridMode()
            })
        if gm.start() {
            grid = gm
            writeStatus(reason: "nested-grid mode")
        }
    }

    /// Vision-OCR hint mode (issue #73 / M5) — captures the main
    /// display, runs `VNRecognizeTextRequest`, surfaces each
    /// recognised text region as a hint. The fallback layer when
    /// even grid is too coarse — the user wants to click the
    /// **specific text** they see, regardless of what's behind it
    /// in the AX layer. Dispatch is `CGEvent` mouse synth at the
    /// recognised centroid.
    func enterVisionMode() {
        // Same overlay-based flow as hint / regional. Use
        // `runHintFlow` so labels, dispatch, and toggle semantics
        // come for free.
        if activeMode == .hint || activeMode == .regional {
            overlay.hide()
            activeMode = nil
        }
        if let s = scroll { s.stop(); scroll = nil }
        if let s = search { s.stop(); search = nil }
        if let g = grid { g.stop(); grid = nil }
        if let n = nudge { n.stop(); nudge = nil }
        if let d = drag { d.stop(); drag = nil }
        runHintFlow(
            elements: source.enumerateVision(),
            modeLabel: "vision",
            mode: .hint,
            reenter: { [weak self] in self?.enterVisionMode() })
    }

    /// Drag mode (issue #69 / M4-δ) — keyboard-driven drag-and-
    /// drop. Enters in `.positioning` (cursor free, no button
    /// held); `d` grabs (mouseDown); arrows move cursor + fire
    /// mouseDragged; `d` / space / Enter releases (mouseUp + exit).
    /// Esc is a safety release — fires mouseUp before exiting so
    /// we don't strand a mouseDown in the system input queue.
    func enterDragMode() {
        if drag != nil {
            cancel()
            return
        }
        cancel()
        let dm = DragMode(
            cancelKey: config.cancelKey,
            onExit: { [weak self] in
                Task { @MainActor [weak self] in self?.drag = nil }
            })
        if dm.start() {
            drag = dm
            writeStatus(reason: "drag mode")
        }
    }

    /// Arrow-nudge mode (issue #68 / M4-γ) — last-mile pixel
    /// adjustment after `--grid` / `--rgrid` lands the cursor
    /// close. No overlay (cursor is the feedback); KeyTap-only
    /// like `ScrollMode`. Toggle on second invocation.
    func enterNudgeMode() {
        if nudge != nil {
            cancel()
            return
        }
        cancel()
        let nm = NudgeMode(
            cancelKey: config.cancelKey,
            onExit: { [weak self] in
                Task { @MainActor [weak self] in self?.nudge = nil }
            })
        if nm.start() {
            nudge = nm
            writeStatus(reason: "nudge mode")
        }
    }

    /// Recursive grid (issue #67 / M4-β) — `--grid` with a
    /// configurable subdivision budget. Each label pick drills
    /// into the chosen cell instead of clicking immediately, up to
    /// `[grid].max-depth` levels. `space` / `Enter` clicks at the
    /// current cell center (terminate early); `Backspace` pops one
    /// level. Pixel-precision tool for AX-blind UIs — three drills
    /// on a 4K screen lands inside a ~5px region.
    func enterRecursiveGridMode() {
        startGridSession(
            maxDepth: config.gridMaxDepth,
            statusReason: "rgrid",
            reenter: { [weak self] in self?.enterRecursiveGridMode() })
    }

    /// Shared `GridMode` builder. Toggle-on-second-press semantics
    /// match the rest of the mode-entry methods.
    private func startGridSession(
        maxDepth: Int,
        statusReason: String,
        reenter: @escaping () -> Void
    ) {
        if grid != nil {
            cancel()
            return
        }
        cancel()            // tear down any other active mode
        let gm = GridMode(
            config: config,
            maxDepth: maxDepth,
            onExit: { [weak self] in
                Task { @MainActor [weak self] in self?.grid = nil }
            },
            onReenter: reenter)
        if gm.start() {
            grid = gm
            writeStatus(reason: "\(statusReason) mode")
        }
    }

    /// Emoji picker (issue #55) — `SearchMode` over the curated
    /// `EmojiTable` (~250 entries; see [Sources/PerchCore/EmojiTable.swift]).
    /// `.press` types the chosen glyph at the focused field's
    /// caret via `CGEvent.keyboardSetUnicodeString` (handled
    /// adapter-side when the id has the `"emoji:"` prefix) —
    /// pasteboard stays untouched, unlike the synthetic
    /// `Cmd+V` approach. `.pressContinuous` re-enters for
    /// multiple-emoji insertion in a row.
    func enterEmojiMode() {
        if search != nil {
            cancel()
            return
        }
        startSearchSession(
            renderMode: .verticalList,
            enumerator: { $0.enumerateEmoji() },
            statusReason: "emoji",
            reenter: { [weak self] in self?.enterEmojiMode() })
    }

    /// Shared builder for the two SearchMode-driven flows
    /// (`--search` and `--menu`). They differ only in:
    ///   - which `UIElementSource` method to enumerate from
    ///     (`enumerate` vs `enumerateMenu`),
    ///   - how matches are painted (pills over frames vs vertical
    ///     list),
    ///   - which mode to re-enter on `.pressContinuous`.
    /// Everything else — KeyTap install, mutual-exclusion against
    /// the other modes, status write, dispatch via `source.act` —
    /// is identical.
    private func startSearchSession(
        renderMode: SearchRenderMode,
        enumerator: @escaping (AXUIElementSource) -> [UIElement],
        statusReason: String,
        reenter: @escaping () -> Void
    ) {
        cancel()
        let sm = SearchMode(
            source: source,
            config: config,
            renderMode: renderMode,
            enumerator: enumerator,
            onResolve: { [weak self] element, action in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.search = nil
                    _ = self.source.act(id: element.id, as: action)
                    self.writeStatus(
                        reason: "\(statusReason) → \(action.rawValue)")
                    if action == .pressContinuous {
                        DispatchQueue.main.async { reenter() }
                    }
                }
            },
            onExit: { [weak self] in
                Task { @MainActor [weak self] in self?.search = nil }
            })
        if sm.start() {
            search = sm
            writeStatus(reason: "\(statusReason) mode")
        }
    }

    private func activate() {
        // Scroll / search / grid / nudge are mutually exclusive
        // with the overlay-based modes — tear them down first.
        if let s = scroll { s.stop(); scroll = nil }
        if let s = search { s.stop(); search = nil }
        if let g = grid { g.stop(); grid = nil }
        if let n = nudge { n.stop(); nudge = nil }
        if let d = drag { d.stop(); drag = nil }
        // Toggle: a second hotkey press (or `--activate`) while
        // hint mode is up cancels and returns.
        if activeMode == .hint {
            overlay.hide()
            activeMode = nil
            return
        }
        // Switching from regional (overlay also up) to hint: tear
        // down the regional overlay first, then enter hint freshly.
        if activeMode == .regional {
            overlay.hide()
            activeMode = nil
        }
        runHintFlow(
            elements: source.enumerate(),
            modeLabel: "activate",
            mode: .hint,
            reenter: { [weak self] in self?.activate() })
    }

    /// Regional hint mode (#34) — Surfingkeys' `L` equivalent on
    /// macOS. Labels large `Group` / `Article` / `Section` /
    /// `SplitGroup` / `ScrollArea` / `Outline` / `Image` containers
    /// (frame >= the configured `[regional].min-width / min-height`
    /// floor, `kAXPressAction` not required) instead of every
    /// clickable leaf. Same overlay + dispatch path as hint mode;
    /// only `source.enumerateRegions()` substitutes for
    /// `source.enumerate()`.
    ///
    /// **Toggle semantics**: a second `--regional` while regional
    /// is already up cancels (matches the doc-stated invariant
    /// "second invocation while the mode is up cancels"). Switching
    /// from hint or scroll / search to regional tears the prior
    /// mode down and enters regional. The user resolves a region
    /// with the same action-mode modifiers (Cmd → copyTitle,
    /// Shift → rightClick, Alt → focus); `.pressContinuous`
    /// (Cmd+Shift) re-enters regional so the user can copy several
    /// region titles in a row.
    func enterRegionalMode() {
        if let s = scroll { s.stop(); scroll = nil }
        if let s = search { s.stop(); search = nil }
        if activeMode == .regional {
            overlay.hide()
            activeMode = nil
            return
        }
        if activeMode == .hint {
            overlay.hide()
            activeMode = nil
        }
        runHintFlow(
            elements: source.enumerateRegions(),
            modeLabel: "regional",
            mode: .regional,
            reenter: { [weak self] in self?.enterRegionalMode() })
    }

    /// Shared between `activate()` (hint mode) and
    /// `enterRegionalMode()` (#34). `elements` is whatever the
    /// caller's enumerator produced; the rest of the pipeline
    /// (Labeler → OverlayWindow.show → onResolve dispatch) is
    /// identical. `modeLabel` distinguishes the log lines so log
    /// triage can tell the modes apart. `mode` is the `ActiveMode`
    /// to record while the overlay is up (so toggle / switch logic
    /// in the entry points can read it back). `reenter` runs on
    /// `.pressContinuous` so each mode re-enters itself rather
    /// than always falling back to hint mode.
    private func runHintFlow(
        elements: [UIElement],
        modeLabel: String,
        mode: ActiveMode,
        reenter: @escaping () -> Void
    ) {
        guard !elements.isEmpty else {
            Log.line("\(modeLabel): no labelable elements — dismissing")
            return
        }
        let screen = NSScreen.main?.frame.size ?? .zero
        let hints = Labeler.assign(
            elements: elements,
            alphabet: config.alphabet,
            prioritiseCenter: config.prioritiseCenter,
            screenSize: screen)
        activeMode = mode
        Log.line("\(modeLabel): \(hints.count) hint(s)")
        // Pass through the bundle id that `enumerate()` just resolved
        // (per `AXUIElementSource.lastEnumeratedBundleID`), NOT a
        // freshly-re-resolved `NSWorkspace.frontmostApplication`. The
        // two would normally agree, but a focus switch between
        // `enumerate()` and this line would otherwise let per-app
        // `roles` / `min-size` apply to (say) Chrome while
        // `auto-click-on-unique` resolved against Word's override.
        sound.playActivate()
        overlay.show(
            hints: hints,
            bundleID: source.lastEnumeratedBundleID,
            onResolve: { [weak self] hint, action in
                guard let self else { return }
                self.activeMode = nil
                // M5+ (#74): nested-grid chord intercepts BEFORE
                // dispatch. Only fires when the picked element is
                // large enough to subdivide meaningfully; for
                // smaller picks fall through to AXPress.
                if action == .nestedGrid {
                    self.enterNestedGridFor(hint: hint)
                    self.writeStatus(
                        reason: "\(modeLabel) → "
                            + "\(hint.keys) (nestedGrid)")
                    return
                }
                _ = self.source.act(id: hint.element.id, as: action)
                self.writeStatus(
                    reason: "\(modeLabel) → "
                        + "\(hint.keys) (\(action.rawValue))")
                // Continuous-follow: after firing, re-enter the
                // SAME mode immediately so the user can chain
                // actions (open 5 links, copy 3 region titles, …)
                // without re-pressing the trigger between each.
                // Deferred to the next runloop tick so the
                // dispatched AX action lands before we re-enumerate.
                if action == .pressContinuous {
                    DispatchQueue.main.async { reenter() }
                }
            },
            onCancel: { [weak self] in
                self?.activeMode = nil
                Log.debug("overlay: cancelled")
            })
    }

    // MARK: - IPC

    /// Subscribe to app-activation notifications so we can pre-warm
    /// Chromium / Electron renderer-AX the moment the user switches
    /// to such an app (#28). Without this, the first hotkey press
    /// after focus-change sees an empty page subtree — Chrome's
    /// renderer-AX wakes asynchronously and is only populated by
    /// the time the user's second activation lands.
    ///
    /// `NSWorkspace.didActivateApplicationNotification` fires on
    /// the main `OperationQueue` (not the main actor under Swift
    /// 6's isolation model), hence the explicit hop. Bundle-id
    /// filtering happens inside `AXUIElementSource.prewarm` so
    /// non-Chromium activations are essentially free.
    private func installAppActivationObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  let bid = app.bundleIdentifier
            else { return }
            let pid = app.processIdentifier
            Task { @MainActor [weak self] in
                self?.source.prewarm(pid: pid, bundleID: bid)
            }
        }
    }

    private func installControlObserver() {
        // The notification block runs on `.main` (an OperationQueue),
        // which is NOT the same as the main actor under Swift 6's
        // model. Hop explicitly so `reload(cause:)` is callable.
        DistributedNotificationCenter.default().addObserver(
            forName: .init(controlNotificationName),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let cmd = note.object as? String ?? ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch cmd {
                case "reload":
                    self.reload(cause: "ipc")
                case "activate":
                    // Same entry point the hotkey trampoline calls.
                    // Symmetric: a second --activate while overlay is
                    // up cancels (matches Carbon hotkey behaviour).
                    Log.line("controller: --activate received")
                    self.activate()
                case "cancel":
                    // Tear down the overlay if it's up; no-op otherwise.
                    Log.line("controller: --cancel received")
                    self.cancel()
                case "scroll":
                    Log.line("controller: --scroll received")
                    self.enterScrollMode()
                case "search":
                    Log.line("controller: --search received")
                    self.enterSearchMode()
                case "regional":
                    Log.line("controller: --regional received")
                    self.enterRegionalMode()
                case "menu":
                    Log.line("controller: --menu received")
                    self.enterMenuMode()
                case "windows":
                    Log.line("controller: --windows received")
                    self.enterWindowMode()
                case "emoji":
                    Log.line("controller: --emoji received")
                    self.enterEmojiMode()
                case "grid":
                    Log.line("controller: --grid received")
                    self.enterGridMode()
                case "rgrid":
                    Log.line("controller: --rgrid received")
                    self.enterRecursiveGridMode()
                case "nudge":
                    Log.line("controller: --nudge received")
                    self.enterNudgeMode()
                case "drag":
                    Log.line("controller: --drag received")
                    self.enterDragMode()
                case "vision":
                    Log.line("controller: --vision received")
                    self.enterVisionMode()
                case "quit":
                    Log.line("controller: --quit received, exiting")
                    // Reverse the renderer-AX wake on every
                    // Chromium / Electron app we touched, so
                    // perch doesn't leak `AXEnhancedUserInterface
                    // = true` past its own lifetime (#33).
                    self.source.clearRendererWake()
                    exit(0)
                default:
                    Log.line("controller: unknown ipc command \"\(cmd)\"")
                }
            }
        }
    }

    private func writeStatus(reason: String) {
        // Discovered WKWebView-host bundles (issue #38) — empty for
        // the common case so the file stays the same shape; only
        // surfaces once perch has seen a WebArea outside the static
        // Chromium allow-list. Sorted in the source so output is
        // stable between calls.
        let discovered = source.discoveredWebBearingBundles
        let discoveredLine = discovered.isEmpty
            ? ""
            : "discovered-web-bundles: "
                + discovered.joined(separator: ", ") + "\n"
        let text = """
        perch: running
        hotkey: \(human(config.hotkey))
        alphabet: \(config.alphabet)
        roles: \(config.roles.count)
        excludes: \(config.excludeApps.count)
        \(discoveredLine)last: \(reason) @ \(Date())
        """
        try? text.write(
            toFile: statusPath, atomically: true, encoding: .utf8)
    }

    private func human(_ combo: HotkeyCombo) -> String {
        var parts: [String] = []
        if combo.modifiers.contains(.ctrl)  { parts.append("ctrl") }
        if combo.modifiers.contains(.alt)   { parts.append("alt") }
        if combo.modifiers.contains(.shift) { parts.append("shift") }
        if combo.modifiers.contains(.cmd)   { parts.append("cmd") }
        parts.append(combo.key)
        return parts.joined(separator: "+")
    }
}

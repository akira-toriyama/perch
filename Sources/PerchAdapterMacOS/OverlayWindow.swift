// Translucent overlay panel that paints one hint pill per visible
// element + intercepts every keyDown while hint mode is up. Lives
// in the adapter layer rather than a separate View module — perch
// has a single on-screen surface and Core stays UI-free (same
// reasoning stroke uses for `GestureOverlay`).
//
// Lifecycle:
//   show(hints:onResolve:onCancel:)   install KeyTap (CGEventTap),
//                                      orderFront the panel, mark
//                                      `appearedAt` for the scale-in
//   set(hints:typed:)                  called after every typed
//                                      character to refresh the
//                                      surviving pills + the
//                                      "matched" highlight
//   hide()                             uninstall tap, orderOut
//
// The panel never activates the app and never steals key focus —
// the underlying app stays frontmost throughout, so the AXPress on
// resolve lands without any focus dance. Keyboard input comes from
// `KeyTap` (session-level CGEventTap), which swallows the events so
// the typed letters don't leak into the focused text field.
//
// Visual design ported from stroke's `GestureOverlay.swift`:
//   - NSVisualEffectView (.hudWindow, .behindWindow), masked to the
//     union of pill rounded rects so only the pills are frosted,
//     not the whole screen
//   - 10pt corner radius, 1pt hair border at white α=0.18, accent
//     2pt border for matched pills
//   - Monospaced 14pt semibold labels, 12 × 9pt padding
//   - 150ms 0.85→1.0 ease-out cubic scale-in on appear
//   - NSShadow glow (blur 7pt, accent α=0.5) on matched pills
//   - 200ms accent-red flash on a missed keypress before dismiss
//   - All effects opt-out via `[overlay].anim-enabled = false`

import AppKit
import CoreGraphics
import Foundation
import PerchCore

@MainActor
public final class OverlayWindow {

    private let panel: NSPanel
    private let canvas: OverlayCanvas
    private var keyTap: KeyTap?
    private var cancelKeyCode: CGKeyCode = 53        // Esc by default
    /// Hold-to-peek key (nil = disabled). While held, the panel is
    /// orderOut'd so the user can see the UI underneath the pills;
    /// the KeyTap stays installed so the keyUp restores the panel.
    /// `peeking` guards against repeated keyDown events from key
    /// auto-repeat firing redundant orderOut calls.
    private var peekKeyCode: CGKeyCode?
    private var peeking = false
    private var hints: [Hint] = []
    private var typed = ""
    private var onResolve: ((Hint, HintAction) -> Void)?
    private var onCancel: (() -> Void)?
    private var config: PerchConfig
    /// Bundle id of the app the controller resolved as frontmost at
    /// `show()` time. Used by the auto-click branch to honour per-app
    /// overrides — passed in (rather than re-resolved here) so the
    /// adapter doesn't grow an `NSWorkspace` dependency for every
    /// hint dispatch.
    private var activeBundleID: String?

    /// Chord-suffix state machine (issue #57). Only active when
    /// `config.chordLeader` is non-empty AND a bare-resolve fired
    /// (no Cmd / Shift / Alt held). Otherwise the existing snappy
    /// resolve path is unchanged.
    private enum ChordPhase {
        case none
        case waitingForLeader   // resolved; next char is `,` or fire-default
        case waitingForChord    // leader pressed; next char picks the action
    }
    private var chordPhase: ChordPhase = .none
    /// The deferred `(hint, default action)` pair, set when we enter
    /// `waitingForLeader`. `finalizeChord` reads and clears it.
    private var pendingResolve: (Hint, HintAction)?
    /// Live timer cancel handle for the chord wait. Replaced on each
    /// phase transition so a `,` press extends the window cleanly.
    private var chordTimer: DispatchWorkItem?
    /// Lookup table mapping chord suffix char → action. Built once
    /// per `show()` so per-call lookup is constant.
    private static let chordActions: [Character: HintAction] = [
        "c": .copyTitle,
        "o": .revealInFinder,
        "u": .copyURL,
        "s": .speakTitle,
        // M4-ε (#70): synthetic modifier-clicks. `m` for Cmd
        // (mnemonic: ⌘ = "command"), `h` for Shift (s already
        // means speakTitle; h is the home-row index finger).
        "m": .synthCmdClick,
        "h": .synthShiftClick,
        // M4-η (#72): multi-click via clickState. `d` = double,
        // `t` = triple — mnemonic from "double" / "triple".
        "d": .doubleClick,
        "t": .tripleClick,
        // M5+ (#74): nested grid. `g` = "grid" mnemonic. The
        // Controller routes this case (it owns GridMode); the
        // adapter's `act(...)` returns true as a no-op so the
        // dispatch log stays clean.
        "g": .nestedGrid,
    ]

    public init(config: PerchConfig) {
        self.config = config

        // NSPanel rather than NSWindow because non-activating
        // panels do not steal focus from the frontmost app — perch
        // needs that frontmost app to remain key so AXPress works
        // immediately on dismissal.
        //
        // Panel covers the UNION of every screen frame, not just
        // NSScreen.main. AX element positions arrive in CG global
        // coords (anchored to the primary display's top-left), so
        // a pill for a Chrome window living on a secondary screen
        // has a canvas-local X past the main screen's width — if
        // the canvas only covered main, that pill would fall off
        // the right edge. The union panel is the only honest fit.
        let frame = OverlayCoords.unionFrame()
        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle,
            .fullScreenAuxiliary,
        ]

        let cv = OverlayCanvas(
            frame: NSRect(origin: .zero, size: frame.size),
            config: config)
        cv.unionFrame = frame
        cv.primaryHeight = OverlayCoords.primaryHeight()
        p.contentView = cv
        self.panel = p
        self.canvas = cv
        self.cancelKeyCode = Self.resolveCancelKeyCode(config.cancelKey)
        self.peekKeyCode = Self.resolvePeekKeyCode(config.overlayPeekKey)
    }

    public func updateConfig(_ cfg: PerchConfig) {
        self.config = cfg
        self.cancelKeyCode = Self.resolveCancelKeyCode(cfg.cancelKey)
        self.peekKeyCode = Self.resolvePeekKeyCode(cfg.overlayPeekKey)
        canvas.updateConfig(cfg)
    }

    /// Show the overlay with the given hints. `onResolve` fires when
    /// the user types a unique label. `onCancel` fires on the
    /// configured cancel key, on a non-letter keypress, or on a
    /// keypress that doesn't match any label prefix (after the
    /// 200ms red-flash, when animations are enabled).
    public func show(
        hints: [Hint],
        bundleID: String? = nil,
        onResolve: @escaping (Hint, HintAction) -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard !hints.isEmpty else { onCancel(); return }
        self.hints = hints
        self.typed = ""
        self.onResolve = onResolve
        self.onCancel = onCancel
        self.activeBundleID = bundleID

        // Re-evaluate the screen union every show() so a display
        // disconnect / reconnect between shows is reflected.
        let union = OverlayCoords.unionFrame()
        let primaryH = OverlayCoords.primaryHeight()
        panel.setFrame(union, display: false)
        canvas.frame = NSRect(origin: .zero, size: union.size)
        canvas.unionFrame = union
        canvas.primaryHeight = primaryH
        Log.line("overlay: union=\(OverlayCoords.rectString(union)) "
                 + "primaryH=\(Int(primaryH)) "
                 + "screens=\(NSScreen.screens.count)")

        canvas.present(hints: hints, typed: typed)
        // .orderFrontRegardless paints the panel without activating
        // perch — the underlying app stays key, its caret keeps
        // blinking, and we avoid the "focus jumped out from under
        // me" experience after AXPress.
        panel.orderFrontRegardless()

        // KeyTap captures keyDown system-wide so we don't need to
        // become the active app to read keys. The tap callback runs
        // on the main thread (CGEventTap dispatches via the run
        // loop source we register on the main loop). We mark
        // @MainActor unconditionally inside `handleKeyDown` for
        // clarity.
        let tap = KeyTap(
            onKeyDown: { [weak self] keyCode, flags, str in
                guard let self else { return false }
                return MainActor.assumeIsolated {
                    self.handleTapKeyDown(
                        keyCode: keyCode, flags: flags, char: str)
                }
            },
            onKeyUp: { [weak self] keyCode in
                guard let self else { return false }
                return MainActor.assumeIsolated {
                    self.handleTapKeyUp(keyCode: keyCode)
                }
            }
        )
        guard tap.install() else {
            Log.line("overlay: keytap install failed — "
                     + "cancelling activation")
            panel.orderOut(nil)
            let cb = onCancel
            self.onCancel = nil
            self.onResolve = nil
            self.hints = []
            cb()
            return
        }
        keyTap = tap
    }

    public func hide() {
        keyTap?.uninstall()
        keyTap = nil
        panel.orderOut(nil)
        canvas.clear()
        hints = []
        typed = ""
        peeking = false
        onResolve = nil
        onCancel = nil
    }

    // MARK: - Key handling

    /// Returns `true` if the event should be swallowed (the user
    /// is in hint mode, the key is one of ours), `false` otherwise.
    /// Letting modified keys (Cmd / Ctrl / Option) through means
    /// the user can still Cmd-Q the focused app or Cmd-Tab out
    /// without the overlay snagging them.
    private func handleTapKeyDown(
        keyCode: CGKeyCode, flags: CGEventFlags, char: String
    ) -> Bool {
        // Chord-suffix phase (issue #57): a bare-resolve is parked
        // waiting for `<leader><action-char>`. Route to the chord
        // state machine FIRST so a stray modifier-less press
        // doesn't fall back into the hint-mode keymap.
        if chordPhase != .none {
            return handleChordKey(
                keyCode: keyCode, flags: flags, char: char)
        }

        // Cancel key (configurable; Esc by default). Match keyCode
        // regardless of modifiers so the user can mash Esc with
        // anything held.
        if keyCode == cancelKeyCode {
            let cb = onCancel
            hide()
            cb?()
            return true
        }

        // Hold-to-peek (#NN): while the peek key is held, orderOut
        // the panel so the user can see the UI underneath. The
        // KeyTap stays installed; the keyUp callback restores the
        // panel. `peeking` short-circuits the repeat-keyDown
        // dispatched by macOS key auto-repeat. Bare press only —
        // a modifier-held press is left to the action-mode branch
        // below so peek doesn't shadow Cmd-Tab / Cmd-Q.
        if let peekKC = peekKeyCode,
           keyCode == peekKC,
           !flags.contains(.maskCommand),
           !flags.contains(.maskAlternate),
           !flags.contains(.maskShift) {
            if !peeking {
                peeking = true
                panel.orderOut(nil)
            }
            return true
        }

        // Control-held is reserved for the user's own shortcuts
        // (Ctrl-C, system shortcuts, etc.) — bail without swallowing.
        // Cmd / Alt / Shift are repurposed as action modifiers (see
        // `actionFor(flags:)`), so they DON'T cancel.
        if flags.contains(.maskControl) {
            let cb = onCancel
            hide()
            cb?()
            return false
        }
        let action = Self.actionFor(flags: flags)

        // Backspace — drop the last typed character.
        if keyCode == 51 {
            if !typed.isEmpty { typed.removeLast() }
            canvas.present(hints: filtered(), typed: typed)
            return true
        }

        // Anything that didn't produce a printable character (arrow
        // keys, F-keys, modifiers alone): red-flash → cancel. Silent
        // input would be confusing.
        guard let ch = char.first, ch.isLetter else {
            flashThenCancel()
            return true
        }

        typed.append(ch)

        let surviving = filtered()
        if surviving.isEmpty {
            // Typed letter that matches no label — keep the failing
            // letter in `typed` so the red flash shows what the user
            // hit, then cancel after the flash window.
            flashThenCancel()
            return true
        }
        // Auto-click on unique candidate (configurable, resolved
        // per-app via `[behavior."<bundle-id>"]`).
        if config.effectiveAutoClickOnUnique(for: activeBundleID),
           surviving.count == 1 {
            deliverResolve(hint: surviving[0], action: action)
            return true
        }
        // Exact match wins immediately.
        if let resolved = Labeler.resolve(hints: hints, keys: typed) {
            deliverResolve(hint: resolved, action: action)
            return true
        }
        canvas.present(hints: surviving, typed: typed)
        return true
    }

    /// Funnel for both resolve paths (auto-click-on-unique and
    /// exact-match). When chord support is enabled AND the action
    /// is the modifier-less default `.press`, defer the dispatch
    /// into the chord wait state; otherwise the existing snappy
    /// path runs unchanged.
    ///
    /// When `[overlay.effect].match != "none"` AND animations are
    /// enabled overall, the winning pill plays its match animation
    /// while AXPress fires in parallel — the user sees the visual
    /// ack riding on top of an already-firing click rather than
    /// after-it.
    private func deliverResolve(hint: Hint, action: HintAction) {
        if action == .press, !config.chordLeader.isEmpty {
            enterChordWait(hint: hint)
            return
        }
        let cb = onResolve
        // Match-effect path: dispatch AXPress synchronously (so the
        // app reacts immediately — the user's perceived click
        // latency is what they care about) but DON'T tear down the
        // overlay until the animation completes. The KeyTap stays
        // installed until hide() so the user can't snag stray keys.
        if config.overlayAnimEnabled, config.matchEffect != .none {
            cb?(hint, action)
            self.onResolve = nil
            canvas.animateMatch(
                winning: hint,
                kind: config.matchEffect,
                intensity: config.effectIntensity
            ) { [weak self] in
                self?.hide()
            }
            return
        }
        hide()
        cb?(hint, action)
    }

    /// Park the resolved hint, keep ONLY the winning pill visible
    /// (every other pill clears) so the user has a clear "you picked
    /// this — waiting for chord" cue, install a timeout, and keep
    /// the KeyTap installed so we can catch the chord suffix. On
    /// timeout we fire `.press` as if no chord arrived; if a chord
    /// arrives, the winning pill is the target of the match
    /// animation. Before issue #NN we orderOut + cleared here,
    /// which silently bypassed every match-effect when chord mode
    /// was on — now the pill stays as the animation anchor.
    private func enterChordWait(hint: Hint) {
        pendingResolve = (hint, .press)
        chordPhase = .waitingForLeader
        // Show only the winning pill with its full label "typed"
        // (so the matched/glow border lights up). The other pills
        // vanish so the user's eye is locked to the pick.
        canvas.present(hints: [hint], typed: hint.keys)
        Log.line("overlay: chord wait → \(hint.keys)")
        scheduleChordTimeout()
    }

    /// Dispatch the chord state machine. Returns whether to
    /// swallow the event.
    ///
    /// - `waitingForLeader`:
    ///   - Esc / cancel-key → abort the pending press
    ///     (`onCancel`-equivalent — the user changed their mind)
    ///   - `chordLeader` → transition to `waitingForChord`, swallow
    ///   - anything else → finalize with `.press`, let the key
    ///     through so the user's deliberate next keystroke
    ///     reaches the focused app
    /// - `waitingForChord`:
    ///   - Esc / cancel-key → abort
    ///   - recognised chord char → finalize with chord action,
    ///     swallow
    ///   - unrecognised char → finalize with `.press`, let through
    private func handleChordKey(
        keyCode: CGKeyCode, flags: CGEventFlags, char: String
    ) -> Bool {
        // Esc / cancel-key during either chord phase: cancel the
        // deferred press entirely.
        if keyCode == cancelKeyCode {
            abortChord()
            return true
        }
        // Ctrl is reserved for user system shortcuts even during
        // chord wait — let the press fall through to .press +
        // pass the Ctrl combo to the focused app.
        if flags.contains(.maskControl) {
            finalizeChord(with: nil)
            return false
        }
        switch chordPhase {
        case .none:
            return false
        case .waitingForLeader:
            if let ch = char.first,
               String(ch).lowercased() == config.chordLeader {
                chordPhase = .waitingForChord
                scheduleChordTimeout()
                return true
            }
            // Not the leader — finalize as plain press and let the
            // typed key reach the focused field.
            finalizeChord(with: nil)
            return false
        case .waitingForChord:
            if let ch = char.first?.lowercased().first,
               let action = Self.chordActions[ch] {
                finalizeChord(with: action)
                return true
            }
            // Unmapped char in chord position — fall back to press
            // and pass the keystroke through.
            finalizeChord(with: nil)
            return false
        }
    }

    /// Fire the pending resolve with either `chordAction` (when set)
    /// or the original `.press` action. Either way: clear chord
    /// state, run the optional match-effect animation, hide the
    /// overlay, and hand control back to the Controller's
    /// `onResolve` callback.
    ///
    /// The animation branch mirrors `deliverResolve`'s — AXPress
    /// fires in parallel so the click isn't delayed. Without this
    /// the chord path silently dropped every match-effect because
    /// `enterChordWait` already had the panel half-torn-down.
    private func finalizeChord(with chordAction: HintAction?) {
        cancelChordTimer()
        guard let (hint, base) = pendingResolve else {
            chordPhase = .none
            return
        }
        pendingResolve = nil
        chordPhase = .none
        let action = chordAction ?? base
        Log.line("overlay: chord finalize \(action.rawValue) "
                 + "→ \(hint.keys)")
        let cb = onResolve
        if config.overlayAnimEnabled, config.matchEffect != .none {
            cb?(hint, action)
            self.onResolve = nil
            canvas.animateMatch(
                winning: hint,
                kind: config.matchEffect,
                intensity: config.effectIntensity
            ) { [weak self] in
                self?.hide()
            }
            return
        }
        hide()
        cb?(hint, action)
    }

    /// Esc during chord wait: drop the deferred press entirely.
    /// The element is NOT clicked — the user explicitly cancelled.
    private func abortChord() {
        cancelChordTimer()
        pendingResolve = nil
        chordPhase = .none
        Log.line("overlay: chord aborted")
        let cb = onCancel
        hide()
        cb?()
    }

    /// (Re-)arm the chord timer with the configured timeout.
    /// Called on each phase entry so the user has the full
    /// timeout window between leader and chord char.
    private func scheduleChordTimeout() {
        cancelChordTimer()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.finalizeChord(with: nil)
            }
        }
        chordTimer = work
        let secs = max(0.05, config.chordTimeoutMs / 1000)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + secs, execute: work)
    }

    private func cancelChordTimer() {
        chordTimer?.cancel()
        chordTimer = nil
    }

    /// Flash the overlay red for 200ms (when anim is enabled) then
    /// dismiss + onCancel. Animations off ⇒ same effect, just
    /// immediate. Keeping `typed` populated during the flash lets
    /// the user see which letter went unmatched.
    ///
    /// `[overlay.effect].unmatch` layers an additional motion
    /// (`shake` / `fade`) on top of the red flash; `none` keeps the
    /// historical "hold for 200ms then dismiss" behavior. The
    /// completion handler gates the hide() so the pills don't
    /// vanish mid-animation.
    private func flashThenCancel() {
        let cb = onCancel
        guard config.overlayAnimEnabled else {
            hide()
            cb?()
            return
        }
        canvas.flashMiss(typed: typed)
        canvas.animateUnmatch(
            kind: config.unmatchEffect,
            intensity: config.effectIntensity
        ) { [weak self] in
            self?.hide()
            cb?()
        }
    }

    private func filtered() -> [Hint] {
        Labeler.filter(hints: hints, prefix: typed)
    }

    /// Map the modifier flags held while the user typed the
    /// resolving letter to a `HintAction`. Ctrl is filtered out at
    /// the call site (it cancels). Bare keypress → `.press`.
    ///
    /// Precedence (top wins when multiple modifiers are held):
    ///   Cmd + Shift → .pressContinuous (continuous-follow / `cf`)
    ///   Cmd alone   → .copyTitle
    ///   Alt         → .focus
    ///   Shift alone → .rightClick
    ///   bare        → .press
    ///
    /// `.pressContinuous` must come BEFORE the plain Cmd check —
    /// `flags.contains(.maskCommand)` is true under either, and we
    /// want the more specific combo to win.
    private static func actionFor(flags: CGEventFlags) -> HintAction {
        if flags.contains(.maskCommand) && flags.contains(.maskShift) {
            return .pressContinuous
        }
        if flags.contains(.maskCommand)   { return .copyTitle }
        if flags.contains(.maskAlternate) { return .focus }
        if flags.contains(.maskShift)     { return .rightClick }
        return .press
    }

    /// Translate a config key name into a CGKeyCode for the
    /// cancel-key comparison. Unknown names silently fall back to
    /// Esc — that's the `typo-can't-break-the-daemon` policy.
    private static func resolveCancelKeyCode(_ name: String) -> CGKeyCode {
        if let kc = HotkeyMonitor.keyCode(for: name) {
            return CGKeyCode(kc)
        }
        Log.line("overlay: unknown cancel key \"\(name)\" — using esc")
        return 53        // kVK_Escape
    }

    /// Translate the configured peek-key name into a CGKeyCode.
    /// Empty string OR unknown name resolves to `nil` (feature
    /// disabled) — unlike `resolveCancelKeyCode` we don't fall
    /// back to a default key, because a peek key the user didn't
    /// ask for is more surprising than no peek.
    private static func resolvePeekKeyCode(_ name: String) -> CGKeyCode? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let kc = HotkeyMonitor.keyCode(for: trimmed) {
            return CGKeyCode(kc)
        }
        Log.line("overlay: unknown peek key \"\(name)\" — disabled")
        return nil
    }

    /// keyUp from the CGEventTap. Only one peek-shaped concern
    /// today: when the user releases the peek key, restore the
    /// panel. We swallow the keyUp in that case so an unmatched
    /// keyUp doesn't reach the focused app (its keyDown was also
    /// swallowed). Other keyUps flow through.
    private func handleTapKeyUp(keyCode: CGKeyCode) -> Bool {
        if peeking, let peekKC = peekKeyCode, keyCode == peekKC {
            peeking = false
            panel.orderFrontRegardless()
            return true
        }
        return false
    }
}

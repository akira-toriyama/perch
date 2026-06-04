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
    }

    public func updateConfig(_ cfg: PerchConfig) {
        self.config = cfg
        self.cancelKeyCode = Self.resolveCancelKeyCode(cfg.cancelKey)
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
        let tap = KeyTap { [weak self] keyCode, flags, str in
            guard let self else { return false }
            return MainActor.assumeIsolated {
                self.handleTapKeyDown(
                    keyCode: keyCode, flags: flags, char: str)
            }
        }
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
        // Cancel key (configurable; Esc by default). Match keyCode
        // regardless of modifiers so the user can mash Esc with
        // anything held.
        if keyCode == cancelKeyCode {
            let cb = onCancel
            hide()
            cb?()
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
            let only = surviving[0]
            let cb = onResolve
            hide()
            cb?(only, action)
            return true
        }
        // Exact match wins immediately.
        if let resolved = Labeler.resolve(hints: hints, keys: typed) {
            let cb = onResolve
            hide()
            cb?(resolved, action)
            return true
        }
        canvas.present(hints: surviving, typed: typed)
        return true
    }

    /// Flash the overlay red for 200ms (when anim is enabled) then
    /// dismiss + onCancel. Animations off ⇒ same effect, just
    /// immediate. Keeping `typed` populated during the flash lets
    /// the user see which letter went unmatched.
    private func flashThenCancel() {
        let cb = onCancel
        guard config.overlayAnimEnabled else {
            hide()
            cb?()
            return
        }
        canvas.flashMiss(typed: typed)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
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
}

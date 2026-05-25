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

    public init(config: PerchConfig) {
        self.config = config

        // NSPanel rather than NSWindow because non-activating
        // panels do not steal focus from the frontmost app — perch
        // needs that frontmost app to remain key so AXPress works
        // immediately on dismissal.
        let frame = NSScreen.main?.frame ?? .zero
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
        onResolve: @escaping (Hint, HintAction) -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard !hints.isEmpty else { onCancel(); return }
        self.hints = hints
        self.typed = ""
        self.onResolve = onResolve
        self.onCancel = onCancel

        // Cover whichever screen is currently key, fall back to
        // main. MVP: single-screen — multi-monitor is a stretch
        // goal (see CLAUDE.md).
        if let screen = NSScreen.main {
            panel.setFrame(screen.frame, display: false)
            canvas.frame = NSRect(origin: .zero, size: screen.frame.size)
            canvas.screenFrame = screen.frame
        }

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
        // Auto-click on unique candidate (configurable).
        if config.autoClickOnUnique, surviving.count == 1 {
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
    /// resolving letter to a `HintAction`. Cmd wins over Alt wins
    /// over Shift if multiple are held; Ctrl is filtered out at
    /// the call site (it cancels). Bare keypress → `.press`.
    private static func actionFor(flags: CGEventFlags) -> HintAction {
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


// MARK: - OverlayCanvas (NSView)

/// Bottom-layer NSView that owns the visual-effect blur and the
/// hint-pill drawing surface. Keeps the blur subview's lifecycle
/// here so `OverlayWindow` doesn't have to thread the blur knob
/// through every accessor — same shape as stroke's `TrailView`.
@MainActor
private final class OverlayCanvas: NSView {

    /// Cocoa-screen frame the canvas is mirroring. AX delivers
    /// elements in screen coords (top-left); we subtract this
    /// frame's origin to get canvas-local coords for drawing.
    var screenFrame: CGRect = .zero

    private var config: PerchConfig
    private var pills: [PillLayout] = []
    private var typed: String = ""
    private var state: VisualState = .idle
    private var appearedAt: TimeInterval?
    private let blurView: NSVisualEffectView
    private let painter: HintPainter

    enum VisualState { case idle, miss }

    init(frame frameRect: NSRect, config: PerchConfig) {
        self.config = config
        // Blur subview is the bottom layer. Mask is rebuilt each
        // layout pass to match the current pill rects so only those
        // areas frost; the rest of the canvas stays transparent.
        let blur = NSVisualEffectView(frame: frameRect)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.autoresizingMask = [.width, .height]
        let mask = CAShapeLayer()
        mask.fillColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        blur.layer?.mask = mask
        self.blurView = blur

        let p = HintPainter(frame: frameRect)
        p.autoresizingMask = [.width, .height]
        self.painter = p

        super.init(frame: frameRect)
        wantsLayer = true
        if config.overlayBlurEnabled {
            addSubview(blur)
        }
        addSubview(painter)
        painter.owner = self
        // Painter starts with nil config — push the initial one so
        // the first `present` lands on a populated painter.
        painter.updateConfig(config)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool {
        // AX gives us top-left frames. Flipping keeps "Y grows
        // down" inside the canvas, so a hint pill's origin lines up
        // with its element without per-frame arithmetic.
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func updateConfig(_ cfg: PerchConfig) {
        let wasBlur = config.overlayBlurEnabled
        config = cfg
        painter.updateConfig(cfg)
        // Toggle blur subview in place when the knob flips.
        if cfg.overlayBlurEnabled != wasBlur {
            if cfg.overlayBlurEnabled {
                if blurView.superview == nil {
                    blurView.frame = bounds
                    addSubview(blurView, positioned: .below, relativeTo: painter)
                }
            } else {
                blurView.removeFromSuperview()
            }
        }
        layoutPills()
    }

    /// Show / refresh the overlay with `hints` and the typed prefix.
    /// First call (the show()) also starts the scale-in animation.
    func present(hints: [Hint], typed: String) {
        let firstFrame = pills.isEmpty
        self.typed = typed
        self.state = .idle
        pills = hints.map { h in
            PillLayout(
                hint: h,
                rect: pillRect(for: h),
                matched: !typed.isEmpty && h.keys.hasPrefix(typed))
        }
        if firstFrame, config.overlayAnimEnabled {
            appearedAt = CACurrentMediaTime()
        }
        layoutPills()
    }

    /// Mark all currently-visible pills as "missed" — the user typed
    /// something we can't match. The painter draws them in red; a
    /// timer (owned by OverlayWindow) calls clear() after the
    /// flash duration.
    func flashMiss(typed: String) {
        self.typed = typed
        self.state = .miss
        // Don't recompute rects — flash uses the same pill layout
        // the user just saw, just recoloured.
        for i in pills.indices {
            pills[i].matched = pills[i].hint.keys.hasPrefix(typed)
        }
        painter.needsDisplay = true
    }

    func clear() {
        pills.removeAll(keepingCapacity: true)
        typed = ""
        state = .idle
        appearedAt = nil
        if let mask = blurView.layer?.mask as? CAShapeLayer {
            mask.path = nil
        }
        painter.needsDisplay = true
    }

    // MARK: - Layout

    private static let pillPadX: CGFloat = 12
    private static let pillPadY: CGFloat = 9
    private static let cornerRadius: CGFloat = 10
    private static let scaleInDuration: TimeInterval = 0.15

    /// Place each pill at the top-left of its target element, with
    /// padding around the label text. Stays inside the canvas
    /// bounds so a pill at the edge isn't clipped off-screen.
    private func pillRect(for hint: Hint) -> CGRect {
        let font = NSFont.monospacedSystemFont(
            ofSize: CGFloat(config.overlayFontSize), weight: .semibold)
        let label = hint.keys.uppercased()
        let textW = (label as NSString).size(
            withAttributes: [.font: font]).width
        let w = ceil(textW) + Self.pillPadX * 2
        let h = ceil(font.boundingRectForFont.height) + Self.pillPadY * 2

        // AX frame is in screen coords; subtract screenFrame.origin
        // for canvas-local coords. Canvas is Y-flipped so AX top-left
        // origin is just origin.
        //
        // No edge clamping — clamping was introducing visible
        // misalignment for elements near the screen edges (the pill
        // moved a few pixels off the element). If a pill would
        // clip against the canvas edge, AppKit clips it naturally
        // at the bounds; far better to clip the pill than to
        // displace it onto a different element.
        let x = hint.element.frame.origin.x - screenFrame.origin.x
        let y = hint.element.frame.origin.y - screenFrame.origin.y
        return CGRect(x: x, y: y, width: w, height: h)
    }

    /// Rebuild the blur mask path (so frost shows only behind pills)
    /// and refresh the painter. Called from `present`, `flashMiss`,
    /// and from itself while the scale-in animation runs.
    private func layoutPills() {
        let scale = currentScale()
        if let mask = blurView.layer?.mask as? CAShapeLayer {
            let path = CGMutablePath()
            for p in pills {
                let t = transform(for: p.rect, scale: scale)
                path.addRoundedRect(
                    in: p.rect,
                    cornerWidth: Self.cornerRadius,
                    cornerHeight: Self.cornerRadius,
                    transform: t)
            }
            mask.path = path
        }
        painter.update(
            pills: pills, typed: typed, state: state, scale: scale)

        // Schedule the next frame if we're still mid-scale-in.
        if scale < 1.0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
                [weak self] in
                MainActor.assumeIsolated { self?.layoutPills() }
            }
        }
    }

    /// Current scale factor for the appear animation. Returns 1.0
    /// when animation is off or finished.
    private func currentScale() -> CGFloat {
        guard let t0 = appearedAt, config.overlayAnimEnabled else { return 1 }
        let elapsed = CACurrentMediaTime() - t0
        if elapsed >= Self.scaleInDuration { return 1 }
        let p = elapsed / Self.scaleInDuration
        let eased = 1 - pow(1 - p, 3)    // ease-out cubic
        return 0.85 + 0.15 * CGFloat(eased)
    }

    /// Build the per-pill scale transform (about the pill's centre)
    /// so the mask scales identically to the painter's content.
    private func transform(for rect: CGRect, scale: CGFloat) -> CGAffineTransform {
        let cx = rect.midX, cy = rect.midY
        return CGAffineTransform(translationX: cx, y: cy)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -cx, y: -cy)
    }

    /// Per-pill geometry + state. Recomputed every `present`.
    fileprivate struct PillLayout {
        let hint: Hint
        let rect: CGRect
        var matched: Bool   // typed prefix matches this label
    }

    var pillsForPainter: [PillLayout] { pills }
}


// MARK: - HintPainter

/// Top layer that paints the pills over `OverlayCanvas`'s blur.
/// Owns no state — reads everything from the bound shared layout
/// computed by `OverlayCanvas.layoutPills`.
@MainActor
private final class HintPainter: NSView {

    weak var owner: OverlayCanvas?
    private var pills: [OverlayCanvas.PillLayout] = []
    private var typed: String = ""
    private var state: OverlayCanvas.VisualState = .idle
    private var scale: CGFloat = 1
    private var config: PerchConfig?

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func updateConfig(_ cfg: PerchConfig) {
        config = cfg
        needsDisplay = true
    }

    func update(
        pills: [OverlayCanvas.PillLayout],
        typed: String,
        state: OverlayCanvas.VisualState,
        scale: CGFloat
    ) {
        self.pills = pills
        self.typed = typed
        self.state = state
        self.scale = scale
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cfg = config else { return }
        let accent = Self.accent(cfg.overlayAccent)
        let label = NSFont.monospacedSystemFont(
            ofSize: CGFloat(cfg.overlayFontSize), weight: .semibold)

        let frosted = cfg.overlayBlurEnabled
        let missColour = NSColor.systemRed

        for p in pills {
            NSGraphicsContext.saveGraphicsState()

            // Per-pill scale-in transform around the pill centre.
            if scale < 1 {
                let cx = p.rect.midX, cy = p.rect.midY
                let tx = NSAffineTransform()
                tx.translateX(by: cx, yBy: cy)
                tx.scaleX(by: scale, yBy: scale)
                tx.translateX(by: -cx, yBy: -cy)
                tx.concat()
            }

            let path = NSBezierPath(
                roundedRect: p.rect, xRadius: 10, yRadius: 10)

            // Drop shadow under the pill — gives the "floating card"
            // feel without changing the perceived geometry. Drawn by
            // re-stroking the path with a shadow set in a saved
            // graphics state (the shadow stays bound to that fill,
            // not the subsequent border / text passes).
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 8
            shadow.shadowOffset = NSSize(width: 0, height: -2)
            shadow.set()
            // We need something to actually cast the shadow — a
            // 1pt token stroke with a transparent colour, which is
            // invisible itself but emits the shadow.
            NSColor.black.withAlphaComponent(0.001).setStroke()
            path.lineWidth = 1
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()

            // Fill. Always tint slightly (even in idle) so white text
            // reads cleanly over the frost. Bumped to a stronger tint
            // for matched / miss state.
            let fill: NSColor
            switch state {
            case .miss:
                fill = missColour.withAlphaComponent(frosted ? 0.55 : 0.85)
            case .idle:
                if p.matched {
                    fill = accent.withAlphaComponent(frosted ? 0.55 : 0.85)
                } else {
                    fill = NSColor.black.withAlphaComponent(frosted ? 0.30 : 0.75)
                }
            }
            fill.setFill()
            path.fill()

            // Glow on matched pills (idle state) so the eye finds
            // the active candidate set instantly. Drawn under the
            // border by saving / restoring graphics state.
            if state == .idle, p.matched {
                NSGraphicsContext.saveGraphicsState()
                let glow = NSShadow()
                glow.shadowColor = accent.withAlphaComponent(0.5)
                glow.shadowBlurRadius = 7
                glow.set()
                accent.withAlphaComponent(0.95).setStroke()
                path.lineWidth = 2
                path.stroke()
                NSGraphicsContext.restoreGraphicsState()
            } else {
                let border: NSColor
                let width: CGFloat
                switch state {
                case .miss:
                    border = missColour.withAlphaComponent(0.95)
                    width = 2
                case .idle:
                    // Faint accent-tinted hairline — gives each pill
                    // a hint of identity colour even at idle, so they
                    // don't read as anonymous grey rectangles when
                    // the user is scanning the screen for hints.
                    border = accent.withAlphaComponent(0.55)
                    width = 1
                }
                border.setStroke()
                path.lineWidth = width
                path.stroke()
            }

            // Label. Already-typed prefix in accent (or red on miss);
            // remainder in white. Drawn via NSAttributedString so the
            // colour split is one paint.
            let upper = p.hint.keys.uppercased()
            let typedUpper = typed.uppercased()
            let prefix = upper.hasPrefix(typedUpper)
                ? String(upper.prefix(typedUpper.count)) : ""
            let suffix = String(upper.dropFirst(prefix.count))
            let prefixColour: NSColor = state == .miss ? missColour : accent

            let attr = NSMutableAttributedString()
            if !prefix.isEmpty {
                attr.append(NSAttributedString(string: prefix, attributes: [
                    .font: label, .foregroundColor: prefixColour]))
            }
            if !suffix.isEmpty {
                attr.append(NSAttributedString(string: suffix, attributes: [
                    .font: label, .foregroundColor: NSColor.white]))
            }
            let textSize = attr.size()
            let textOrigin = NSPoint(
                x: p.rect.midX - textSize.width / 2,
                y: p.rect.midY - textSize.height / 2)
            attr.draw(at: textOrigin)

            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func accent(_ s: String) -> NSColor {
        if s == "system" { return .controlAccentColor }
        var t = s
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let v = UInt32(t, radix: 16) else {
            return .controlAccentColor
        }
        return NSColor(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green:    CGFloat((v >> 8) & 0xFF) / 255,
            blue:     CGFloat(v & 0xFF) / 255,
            alpha: 1)
    }
}

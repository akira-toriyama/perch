// Bottom-layer NSView that owns the visual-effect blur and the
// hint-pill drawing surface. Keeps the blur subview's lifecycle
// here so `OverlayWindow` doesn't have to thread the blur knob
// through every accessor — same shape as stroke's `TrailView`.
//
// Coordinate-system note for future contributors: `OverlayCanvas`
// is `isFlipped = true` (so AX top-left frames map straight to
// canvas-local coords). The `NSVisualEffectView` underneath is
// NOT flipped — its `CALayer` mask uses Y-up from bottom-left.
// `layoutPills` flips Y explicitly when handing rects into the
// mask path. If you add any other layer-backed sublayer to the
// blur view, it must follow the same convention. Skipping this
// produces silent "frost mirrored to the bottom of the screen"
// artifacts that took several PRs to track down (see PR #16).

import AppKit
import CoreGraphics
import Foundation
import PerchCore

@MainActor
final class OverlayCanvas: NSView {

    /// Union of every screen frame in Cocoa global coords. The
    /// canvas covers this rect 1:1 (it's the panel's contentRect).
    /// Filled in by `OverlayWindow.show()` via `OverlayCoords.unionFrame()`.
    var unionFrame: CGRect = .zero

    /// Height of the screen at Cocoa origin — the "primary" CG
    /// global coords are anchored to. Used to convert AX positions
    /// (CG, top-left primary) into canvas-local flipped coords:
    /// `canvasCGTopY = primaryHeight - unionFrame.maxY`.
    var primaryHeight: CGFloat = 0

    private var config: PerchConfig
    private var pills: [PillLayout] = []
    private var typed: String = ""
    private var state: VisualState = .idle
    private var appearedAt: TimeInterval?
    private let blurView: NSVisualEffectView
    private let painter: HintPainter

    /// Idle = the "showing hints, waiting for input" state.
    /// Miss = a keypress that didn't match any label; the painter
    /// recolours the pills red for the flash window before
    /// `OverlayWindow` tears the canvas down.
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

    /// Place each pill at the top-left of its target element. The
    /// CG → canvas math is delegated to `OverlayCoords` so the
    /// formula lives in one place — anything else that paints over
    /// AX-positioned elements (search overlay, future region
    /// hints) uses the same conversion.
    ///
    /// No edge clamping: clamping was silently displacing pills
    /// for elements near the screen edges (a few points off their
    /// targets). If a pill would clip against the canvas edge,
    /// AppKit clips it naturally — far better than displacing.
    private func pillRect(for hint: Hint) -> CGRect {
        let font = NSFont.monospacedSystemFont(
            ofSize: CGFloat(config.overlayFontSize), weight: .semibold)
        let label = hint.keys.uppercased()
        let textW = (label as NSString).size(
            withAttributes: [.font: font]).width
        let w = ceil(textW) + Self.pillPadX * 2
        let h = ceil(font.boundingRectForFont.height) + Self.pillPadY * 2

        let local = OverlayCoords.canvasLocal(
            cg: hint.element.frame.origin,
            unionFrame: unionFrame,
            primaryHeight: primaryHeight)
        return CGRect(x: local.x, y: local.y, width: w, height: h)
    }

    /// Rebuild the blur mask path (so frost shows only behind pills)
    /// and refresh the painter. Called from `present`, `flashMiss`,
    /// and from itself while the scale-in animation runs.
    ///
    /// Coordinate-system note: `pill.rect` is in canvas's flipped
    /// (top-left origin) coords. The blurView's `CAShapeLayer` mask
    /// uses Y-up from bottom-left because `NSVisualEffectView` is
    /// not flipped. Flip Y explicitly here when crossing into the
    /// mask layer's coord system — skipping this surfaces as empty
    /// pill-shaped frost rectangles mirrored to the bottom of the
    /// canvas (PR #16). Same constraint applies to anything else
    /// added to the mask layer in the future.
    private func layoutPills() {
        let scale = currentScale()
        let canvasH = bounds.height
        if let mask = blurView.layer?.mask as? CAShapeLayer {
            let path = CGMutablePath()
            for p in pills {
                let unflipped = CGRect(
                    x: p.rect.minX,
                    y: canvasH - p.rect.maxY,
                    width: p.rect.width,
                    height: p.rect.height)
                let t = transform(for: unflipped, scale: scale)
                path.addRoundedRect(
                    in: unflipped,
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
    /// `internal` rather than `fileprivate` so `HintPainter` (in
    /// its own file) can read the array via `update(pills:…)`.
    struct PillLayout {
        let hint: Hint
        let rect: CGRect
        var matched: Bool   // typed prefix matches this label
    }
}

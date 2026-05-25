// Top layer that paints the pills over `OverlayCanvas`'s blur.
// Owns no state — reads everything via `update(pills:…)` from the
// shared layout `OverlayCanvas.layoutPills` computes.
//
// All the visual choices stroke's `GestureOverlay` makes show up
// here: 10pt corner radius via NSBezierPath, accent hairline at
// idle, accent stroke + NSShadow glow when typed-matched, drop
// shadow under every pill for the floating-card feel. Drawn in a
// flipped (top-left origin) context to line up with AX coords.

import AppKit
import CoreGraphics
import Foundation
import PerchCore

@MainActor
final class HintPainter: NSView {

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

    /// Translate `[overlay].accent` (either `"system"` or
    /// `"#rrggbb"`) into an `NSColor`. Anything we can't parse
    /// falls back to `NSColor.controlAccentColor` — `PerchConfig`
    /// already drops malformed values before we get here, so this
    /// is the belt-and-braces tier.
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

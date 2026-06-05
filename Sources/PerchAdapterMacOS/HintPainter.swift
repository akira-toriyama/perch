// Top layer that paints the pills over `OverlayCanvas`'s blur.
// Owns no state — reads everything via `update(pills:…)` from the
// shared layout `OverlayCanvas.layoutPills` computes.
//
// All the visual choices stroke's `GestureOverlay` makes show up
// here: 10pt corner radius via NSBezierPath, accent hairline at
// idle, accent stroke + NSShadow glow when typed-matched, drop
// shadow under every pill for the floating-card feel. Drawn in a
// flipped (top-left origin) context to line up with AX coords.
//
// Theme palette resolution (`[overlay] theme`, see facet for the
// vocabulary): `resolvePalette(cfg:)` decodes the theme into
// `(pillBgColor, accentColor, textColor, missColor, fontKind)`
// once per `update(…)`. `overlayAccent != "system"` overrides the
// palette's accent so users can mix a body theme with a personal
// accent ("nord pills, hot-pink highlight").

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
    /// Per-pill 2D translation offset shared by shake / vibrate /
    /// drop / rise / slide-left / slide-right. 0 = no offset.
    /// OverlayCanvas drives this via `setOffset(dx:dy:)`.
    private var offsetDx: CGFloat = 0
    private var offsetDy: CGFloat = 0
    /// Per-pill opacity multiplier applied to ALL pills (vs the
    /// winning-only `matchOpacity` below). Drives the unmatch
    /// fade variants. 1 = no fade.
    private var pillsAlpha: CGFloat = 1
    /// Per-pill scale + opacity for the `match` effect on the
    /// winning pill (others stay at 1.0 / 1.0). OverlayCanvas drives
    /// `setMatchAnim(winningHintKeys:scale:opacity:dx:dy:)` so this
    /// view stays state-free.
    private var matchWinningKeys: String?
    private var matchScale: CGFloat = 1
    private var matchOpacity: CGFloat = 1
    private var matchDx: CGFloat = 0
    private var matchDy: CGFloat = 0
    /// Active particle list — fireworks / confetti drivers update
    /// this each tick. Empty = nothing to draw. Particles are drawn
    /// AFTER pills so they sit on top.
    private var particles: [Particle] = []
    private var config: PerchConfig?

    /// One active particle. Drawn as a small filled circle in
    /// `color` at `(x, y)` with current alpha. Position / velocity /
    /// alpha are advanced per tick by the OverlayCanvas driver —
    /// HintPainter is a pure renderer.
    struct Particle {
        var x: CGFloat
        var y: CGFloat
        var radius: CGFloat
        var color: NSColor
        var alpha: CGFloat
    }

    /// One animating "ghost" pill — a previously-visible pill that's
    /// been filtered out by a typed prefix. Carries its original rect
    /// (so the animation starts in place), the per-tick transform
    /// state driven by the narrow-effect driver, and the hint label
    /// so the user can still read which pill is disappearing.
    struct Ghost {
        let hint: Hint
        let baseRect: CGRect
        var scale: CGFloat
        var dx: CGFloat
        var dy: CGFloat
        var alpha: CGFloat
    }

    /// Active ghost pills — drawn AFTER live pills so a slow-fading
    /// ghost rests on top, but BEFORE particles. Driver in
    /// OverlayCanvas updates this each tick.
    private var ghosts: [Ghost] = []

    /// Currently-held modifier flags (Cmd / Shift / Alt / Ctrl).
    /// Drives the modifier-badge corner glyph when
    /// `[overlay].show-modifier-badge` is on.
    private var modifierFlags: CGEventFlags = []

    /// Normalised hue rotation for the border effect (0..1). The
    /// OverlayCanvas cycle driver updates this each tick when
    /// `[overlay.border].cycle-seconds > 0`. 0 = base hue; 0.5 =
    /// 180° around the wheel; 1 ≡ 0.
    private var borderHueOffset: CGFloat = 0

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

    /// Set the all-pill translation offset (shake / vibrate / slide
    /// / drop / rise drivers). Y is in canvas-flipped coords
    /// (positive = downward).
    func setOffset(dx: CGFloat, dy: CGFloat) {
        offsetDx = dx
        offsetDy = dy
        needsDisplay = true
    }

    /// Set the all-pill alpha (unmatch.fade and the translation
    /// effects drive this — translating off-screen pairs with a
    /// fade so the user doesn't see the pill cross the bezel).
    func setPillsAlpha(_ alpha: CGFloat) {
        pillsAlpha = alpha
        needsDisplay = true
    }

    /// Set the winning-pill match animation state. `winningHintKeys
    /// == nil` clears the highlight (return to baseline).
    func setMatchAnim(
        winningHintKeys: String?,
        scale: CGFloat,
        opacity: CGFloat,
        dx: CGFloat = 0,
        dy: CGFloat = 0
    ) {
        matchWinningKeys = winningHintKeys
        matchScale = scale
        matchOpacity = opacity
        matchDx = dx
        matchDy = dy
        needsDisplay = true
    }

    /// Replace the particle list. Empty array clears.
    func setParticles(_ ps: [Particle]) {
        particles = ps
        needsDisplay = true
    }

    /// Replace the ghost list. Empty array clears the narrow-effect
    /// overlay (call site uses this when all ghosts finish their
    /// animation and the driver shuts down).
    func setGhosts(_ gs: [Ghost]) {
        ghosts = gs
        needsDisplay = true
    }

    /// Update the currently-held modifier flags. The badge corner
    /// glyph repaints to match (only when the config opted in via
    /// `show-modifier-badge`).
    func setModifierFlags(_ flags: CGEventFlags) {
        modifierFlags = flags
        needsDisplay = true
    }

    /// Set the border hue offset for the neon-border effect.
    /// Driver in OverlayCanvas updates this each tick while
    /// `[overlay.border].cycle-seconds > 0`.
    func setBorderHueOffset(_ offset: CGFloat) {
        borderHueOffset = offset
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cfg = config else { return }
        let palette = Self.resolvePalette(cfg: cfg)
        let label = Self.labelFont(palette.font, size: cfg.overlay.fontSize)

        let frosted = cfg.overlay.blurEnabled
        let pillBgIdle = Self.color(
            hex: palette.pillBgHex,
            alpha: frosted ? palette.pillBgAlpha : min(palette.pillBgAlpha + 0.45, 1))
        let pillBgMatched = palette.accentColor.withAlphaComponent(
            frosted ? 0.55 : 0.85)
        let pillBgMiss = palette.missColor.withAlphaComponent(
            frosted ? 0.55 : 0.85)

        for p in pills {
            NSGraphicsContext.saveGraphicsState()

            // Compose three sources of motion on each pill:
            //   - per-pill appear state (scale/dx/dy/alpha) from
            //     `[overlay.effect].appear` — cascade staggers each
            //     pill independently, the others apply uniformly
            //   - winning-pill match-effect (`matchScale` + `matchDx/Dy`)
            //   - all-pill offset (shake / vibrate / drop / rise / slide)
            // The winning pill stacks match-anim with its appear state;
            // the all-pill offset path is suppressed for the winner
            // (unmatch + match don't fire at the same time so this
            // mostly matters in theory).
            let isWinning = (matchWinningKeys == p.hint.keys)
            let composedScale: CGFloat = isWinning
                ? p.appearScale * matchScale
                : p.appearScale
            let composedDx: CGFloat =
                isWinning ? p.appearDx + matchDx : p.appearDx + offsetDx
            let composedDy: CGFloat =
                isWinning ? p.appearDy + matchDy : p.appearDy + offsetDy
            if composedScale != 1 || composedDx != 0 || composedDy != 0 {
                let cx = p.rect.midX, cy = p.rect.midY
                let tx = NSAffineTransform()
                tx.translateX(by: composedDx, yBy: composedDy)
                tx.translateX(by: cx, yBy: cy)
                tx.scaleX(by: composedScale, yBy: composedScale)
                tx.translateX(by: -cx, yBy: -cy)
                tx.concat()
            }

            // Alpha gate. Four sources stack:
            //   - per-pill appear alpha (`p.appearAlpha`, fade-in /
            //     cascade / bloom / drop-in chain)
            //   - winning-only match fade (`matchOpacity`)
            //   - all-pill alpha (`pillsAlpha`, drives unmatch.fade
            //     + the off-screen-translation effects)
            //   - the implicit 1.0 baseline for non-winning pills
            //     during match
            let pillAlpha: CGFloat = isWinning
                ? p.appearAlpha * matchOpacity
                : p.appearAlpha * pillsAlpha
            if pillAlpha < 1, let ctx = NSGraphicsContext.current {
                ctx.cgContext.setAlpha(pillAlpha)
                ctx.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
            }

            let shape = Self.shapeFor(
                cfg: cfg, hint: p.hint, rect: p.rect)
            let path = shape.path

            // Body draw (shadow / fill / border) — suppressed for
            // `.underline` so only the accent bar + text render.
            // The minimalist shapes keep the same matched/miss
            // semantics so the user's eye still tracks the typed
            // prefix.
            if shape.drawBody {
                // Drop shadow under the pill — gives the "floating
                // card" feel. Drawn by re-stroking the path with a
                // shadow set in a saved graphics state.
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
                shadow.shadowBlurRadius = 8
                shadow.shadowOffset = NSSize(width: 0, height: -2)
                shadow.set()
                NSColor.black.withAlphaComponent(0.001).setStroke()
                path.lineWidth = 1
                path.stroke()
                NSGraphicsContext.restoreGraphicsState()

                // Fill. Theme palette provides the pill bg; matched /
                // miss states swap to accent / red tints respectively.
                let fill: NSColor
                switch state {
                case .miss:
                    fill = pillBgMiss
                case .idle:
                    fill = p.matched ? pillBgMatched : pillBgIdle
                }
                fill.setFill()
                path.fill()

                // Glow on matched pills (idle state) so the eye
                // finds the active candidate set instantly.
                if state == .idle, p.matched {
                    NSGraphicsContext.saveGraphicsState()
                    let glow = NSShadow()
                    glow.shadowColor = palette.accentColor.withAlphaComponent(0.5)
                    glow.shadowBlurRadius = 7
                    glow.set()
                    palette.accentColor.withAlphaComponent(0.95).setStroke()
                    path.lineWidth = 2
                    path.stroke()
                    NSGraphicsContext.restoreGraphicsState()
                } else if state == .idle, cfg.border.effect != .off {
                    // Neon border preset — replaces the default
                    // accent hairline for non-matched idle pills.
                    // Uses the configured width + optional glow,
                    // hue-rotated by the current cycle offset so a
                    // long-lived overlay paints a slow palette
                    // rotation. Matched pills (above) keep the
                    // accent path so the typed-prefix highlight
                    // stays visually distinct.
                    drawNeonBorder(
                        path: path, cfg: cfg, palette: palette)
                } else {
                    let border: NSColor
                    let width: CGFloat
                    switch state {
                    case .miss:
                        border = palette.missColor.withAlphaComponent(0.95)
                        width = 2
                    case .idle:
                        border = palette.accentColor.withAlphaComponent(0.55)
                        width = 1
                    }
                    border.setStroke()
                    path.lineWidth = width
                    path.stroke()
                }
            }

            // Accent bar (underline mode) — drawn instead of the
            // body, in the matched/miss-aware accent so the user
            // still gets a visual cue for the typed prefix.
            if let bar = shape.accentBar {
                let barColor: NSColor
                switch state {
                case .miss:
                    barColor = palette.missColor
                case .idle:
                    barColor = p.matched
                        ? palette.accentColor
                        : palette.accentColor.withAlphaComponent(0.55)
                }
                barColor.setFill()
                bar.fill()
            }

            // Label. Already-typed prefix in accent (or red on miss);
            // remainder in the theme's text color. Drawn via
            // NSAttributedString so the colour split is one paint.
            let upper = p.hint.keys.uppercased()
            let typedUpper = typed.uppercased()
            let prefix = upper.hasPrefix(typedUpper)
                ? String(upper.prefix(typedUpper.count)) : ""
            let suffix = String(upper.dropFirst(prefix.count))
            let prefixColour: NSColor =
                state == .miss ? palette.missColor : palette.accentColor

            let attr = NSMutableAttributedString()
            if !prefix.isEmpty {
                attr.append(NSAttributedString(string: prefix, attributes: [
                    .font: label, .foregroundColor: prefixColour]))
            }
            if !suffix.isEmpty {
                attr.append(NSAttributedString(string: suffix, attributes: [
                    .font: label, .foregroundColor: palette.textColor]))
            }
            let textSize = attr.size()
            let textOrigin = NSPoint(
                x: p.rect.midX - textSize.width / 2,
                y: p.rect.midY - textSize.height / 2)
            attr.draw(at: textOrigin)

            // Modifier-key badge (top-right corner). Active only
            // when configured + at least one tracked modifier is
            // held. The glyph confirms the action that will fire
            // on resolve so the user doesn't have to remember the
            // Cmd/Shift/Alt → action mapping.
            if cfg.overlay.showModifierBadge, !modifierFlags.isEmpty {
                drawModifierBadge(
                    rect: p.rect,
                    flags: modifierFlags,
                    palette: palette)
            }

            if pillAlpha < 1, let ctx = NSGraphicsContext.current {
                ctx.cgContext.endTransparencyLayer()
                ctx.cgContext.setAlpha(1)
            }

            NSGraphicsContext.restoreGraphicsState()
        }

        // Ghost pills — pills that were just filtered out by the
        // typed prefix and are animating their narrow-effect exit.
        // Draw AFTER live pills so an in-flight ghost can briefly
        // overlap a surviving pill without flickering underneath.
        // Bigger structure than live-pill draw is intentional: a
        // ghost carries its own (scale, dx, dy, alpha) channel and
        // doesn't react to typed-prefix matching (it's already
        // "lost" the match by definition).
        for g in ghosts where g.alpha > 0.01 {
            drawGhost(g, palette: palette, font: label, frosted: frosted)
        }

        // Particles sit ON TOP of the pills (fireworks / confetti).
        // Drawn as filled circles in their tinted color at current
        // alpha — driver clears the list when the burst finishes.
        for part in particles where part.alpha > 0 {
            NSGraphicsContext.saveGraphicsState()
            part.color.withAlphaComponent(part.alpha).setFill()
            let rect = NSRect(
                x: part.x - part.radius,
                y: part.y - part.radius,
                width: part.radius * 2,
                height: part.radius * 2)
            NSBezierPath(ovalIn: rect).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Paint a single ghost pill with its own transform / alpha. No
    /// matched / glow / prefix-highlight logic — a ghost has by
    /// definition lost its match, so it's drawn in the theme's
    /// idle look with a uniform fade. Shares the rounded-rect /
    /// border / text styling with `draw(_:)` so a ghost reads
    /// visually as "the same pill, on its way out".
    private func drawGhost(
        _ g: Ghost,
        palette: ResolvedPalette,
        font: NSFont,
        frosted: Bool
    ) {
        guard let cfg = config else { return }
        NSGraphicsContext.saveGraphicsState()
        if g.scale != 1 || g.dx != 0 || g.dy != 0 {
            let cx = g.baseRect.midX, cy = g.baseRect.midY
            let tx = NSAffineTransform()
            tx.translateX(by: g.dx, yBy: g.dy)
            tx.translateX(by: cx, yBy: cy)
            tx.scaleX(by: g.scale, yBy: g.scale)
            tx.translateX(by: -cx, yBy: -cy)
            tx.concat()
        }
        if g.alpha < 1, let ctx = NSGraphicsContext.current {
            ctx.cgContext.setAlpha(g.alpha)
            ctx.cgContext.beginTransparencyLayer(auxiliaryInfo: nil)
        }

        let shape = Self.shapeFor(
            cfg: cfg, hint: g.hint, rect: g.baseRect)
        let path = shape.path
        let pillBg = Self.color(
            hex: palette.pillBgHex,
            alpha: frosted ? palette.pillBgAlpha : min(palette.pillBgAlpha + 0.45, 1))
        if shape.drawBody {
            pillBg.setFill()
            path.fill()
            palette.accentColor.withAlphaComponent(0.55).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        if let bar = shape.accentBar {
            palette.accentColor.withAlphaComponent(0.55).setFill()
            bar.fill()
        }

        let upper = g.hint.keys.uppercased()
        let attr = NSAttributedString(string: upper, attributes: [
            .font: font, .foregroundColor: palette.textColor])
        let textSize = attr.size()
        attr.draw(at: NSPoint(
            x: g.baseRect.midX - textSize.width / 2,
            y: g.baseRect.midY - textSize.height / 2))

        if g.alpha < 1, let ctx = NSGraphicsContext.current {
            ctx.cgContext.endTransparencyLayer()
            ctx.cgContext.setAlpha(1)
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: - Neon border

    /// Stroke the pill border with the configured neon preset.
    /// Uses `cfg.border.width` + an optional NSShadow glow when
    /// `cfg.border.glow` is true. The base color comes from the
    /// `BorderEffect` palette (or `palette.accentColor` if the
    /// effect somehow lacks a hex), then rotated by
    /// `borderHueOffset` so a cycle period rotates the hue.
    private func drawNeonBorder(
        path: NSBezierPath,
        cfg: PerchConfig,
        palette: ResolvedPalette
    ) {
        let baseHex = cfg.border.effect.baseHex ?? 0xFFFFFF
        var color = Self.color(hex: baseHex, alpha: 1)
        // Rotate hue around the wheel. For `.rainbow` the base is
        // white so saturation jumps from 0 to 1 — produce a
        // saturated color at the rotated hue. For colored bases,
        // shift the existing hue.
        if borderHueOffset != 0 {
            color = Self.rotateHue(color, by: borderHueOffset)
        }
        NSGraphicsContext.saveGraphicsState()
        if cfg.border.glow {
            let glow = NSShadow()
            glow.shadowColor = color.withAlphaComponent(0.7)
            glow.shadowBlurRadius = 6
            glow.set()
        }
        color.withAlphaComponent(0.95).setStroke()
        path.lineWidth = CGFloat(cfg.border.width)
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Rotate the given color's hue by `offset` (0..1) around the
    /// color wheel. White input lands with saturation pulled up to
    /// 1.0 so the rotation actually produces visible color — the
    /// `.rainbow` border preset depends on this so its white base
    /// hex doesn't render as a stationary grey.
    static func rotateHue(_ color: NSColor, by offset: CGFloat) -> NSColor {
        let conv = color.usingColorSpace(.deviceRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 1, a: CGFloat = 1
        conv.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let newH = (h + offset).truncatingRemainder(dividingBy: 1)
        let newS = max(s, 0.9)        // ensure white inputs colourise
        return NSColor(
            hue: newH < 0 ? newH + 1 : newH,
            saturation: newS,
            brightness: max(b, 0.85),
            alpha: a)
    }

    // MARK: - Modifier badge

    /// Compose the macOS modifier glyph string for the held flags.
    /// Order matches Apple's canonical glyph order (`⌃⌥⇧⌘`) so the
    /// badge reads like a real keyboard-shortcut annotation. Ctrl
    /// is included even though it cancels hint mode — users may
    /// glance at the pill while pressing Ctrl mid-stream and the
    /// badge should reflect what's actually held.
    private func modifierGlyph(_ flags: CGEventFlags) -> String {
        var s = ""
        if flags.contains(.maskControl)   { s += "\u{2303}" }   // ⌃
        if flags.contains(.maskAlternate) { s += "\u{2325}" }   // ⌥
        if flags.contains(.maskShift)     { s += "\u{21E7}" }   // ⇧
        if flags.contains(.maskCommand)   { s += "\u{2318}" }   // ⌘
        return s
    }

    /// Paint the modifier-badge glyph in the pill's top-right
    /// corner. Sized to fit comfortably in the pill's edge gutter;
    /// uses the accent color so it pops against the body fill.
    private func drawModifierBadge(
        rect: CGRect,
        flags: CGEventFlags,
        palette: ResolvedPalette
    ) {
        let glyph = modifierGlyph(flags)
        guard !glyph.isEmpty else { return }
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let attr = NSAttributedString(string: glyph, attributes: [
            .font: font,
            .foregroundColor: palette.accentColor.withAlphaComponent(0.95)])
        let sz = attr.size()
        // Anchor the glyph to the pill's top-right corner with a
        // 3pt inset so it doesn't kiss the border.
        let origin = NSPoint(
            x: rect.maxX - sz.width - 3,
            y: rect.minY + 1)
        attr.draw(at: origin)
    }

    // MARK: - Pill geometry

    /// Per-pill geometry resolved from `[overlay].pill-shape`. The
    /// painter draws `path` (when `drawBody`) and `accentBar` (always
    /// if non-nil). Underline mode suppresses the body path entirely
    /// — only the accent bar + text are rendered.
    struct PillGeometry {
        let path: NSBezierPath
        let drawBody: Bool
        let accentBar: NSBezierPath?
    }

    /// Build the body path + optional accent overlay for one pill.
    /// `.circle` falls back to `.pill` when the label is 2+ chars
    /// because a circle that fits "aa" is too large for the
    /// surrounding pills' density.
    static func shapeFor(
        cfg: PerchConfig, hint: Hint, rect: CGRect
    ) -> PillGeometry {
        switch cfg.overlay.pillShape {
        case .pill:
            return PillGeometry(
                path: NSBezierPath(
                    roundedRect: rect, xRadius: 10, yRadius: 10),
                drawBody: true, accentBar: nil)
        case .square:
            return PillGeometry(
                path: NSBezierPath(
                    roundedRect: rect, xRadius: 1, yRadius: 1),
                drawBody: true, accentBar: nil)
        case .circle:
            // Single-char labels only — multi-char would force the
            // circle to grow large enough that the dense layout
            // breaks. The pill fallback keeps things readable.
            guard hint.keys.count == 1 else {
                return PillGeometry(
                    path: NSBezierPath(
                        roundedRect: rect, xRadius: 10, yRadius: 10),
                    drawBody: true, accentBar: nil)
            }
            let d = min(rect.width, rect.height)
            let sq = CGRect(
                x: rect.midX - d / 2, y: rect.midY - d / 2,
                width: d, height: d)
            return PillGeometry(
                path: NSBezierPath(ovalIn: sq),
                drawBody: true, accentBar: nil)
        case .underline:
            // Skip body entirely; a 2pt accent bar under the label
            // provides the visual anchor. The body path is kept for
            // anyone (future hit-test) who needs it.
            let barH: CGFloat = 2
            let bar = NSBezierPath(rect: CGRect(
                x: rect.minX + 4, y: rect.maxY - barH,
                width: rect.width - 8, height: barH))
            return PillGeometry(
                path: NSBezierPath(rect: rect),
                drawBody: false, accentBar: bar)
        case .tag:
            // Rounded body + a 6pt triangle pointing left at the
            // element. Appended to the same path so fill / border
            // pick up both in one stroke.
            let p = NSBezierPath(
                roundedRect: rect, xRadius: 10, yRadius: 10)
            let triH: CGFloat = 8
            let tip = NSPoint(x: rect.minX - 6, y: rect.midY)
            let top = NSPoint(x: rect.minX, y: rect.midY - triH / 2)
            let bot = NSPoint(x: rect.minX, y: rect.midY + triH / 2)
            let tri = NSBezierPath()
            tri.move(to: tip)
            tri.line(to: top)
            tri.line(to: bot)
            tri.close()
            p.append(tri)
            return PillGeometry(path: p, drawBody: true, accentBar: nil)
        }
    }

    // MARK: - Theme resolution

    /// Resolved palette as `NSColor`s + font kind. `overlayAccent`
    /// (when non-"system") wins over the theme's accent so the
    /// user can layer a personal highlight onto any palette.
    struct ResolvedPalette {
        let pillBgHex: UInt32
        let pillBgAlpha: CGFloat
        let accentColor: NSColor
        let textColor: NSColor
        let missColor: NSColor
        let font: ThemeFont
    }

    /// Module-internal so OverlayCanvas's particle driver can read
    /// the accent color for tinting bursts.
    static func resolvePalette(cfg: PerchConfig) -> ResolvedPalette {
        let raw = cfg.overlay.theme.palette()
        // `.system` palette uses `accentHex == 0` as a sentinel — fall
        // back to NSColor.controlAccentColor so light/dark + the user's
        // chosen macOS accent are honored.
        let themeAccent: NSColor =
            raw.accentHex == 0
                ? .controlAccentColor
                : color(hex: raw.accentHex, alpha: 1)
        // `[overlay].accent` overrides the palette's accent when set
        // to anything other than the default "system". Lets users mix
        // a theme body (nord pill colors / rounded font) with a
        // personal highlight.
        let accent: NSColor
        if cfg.overlay.accent == "system" {
            accent = themeAccent
        } else {
            accent = parseAccent(cfg.overlay.accent) ?? themeAccent
        }
        return ResolvedPalette(
            pillBgHex: raw.pillBgHex,
            pillBgAlpha: raw.pillBgAlpha,
            accentColor: accent,
            textColor: color(hex: raw.textHex, alpha: 1),
            missColor: color(hex: raw.missHex, alpha: 1),
            font: raw.font)
    }

    /// Translate a `0xRRGGBB` int + alpha into an `NSColor` in the
    /// sRGB color space (matches NSColor.controlAccentColor's color
    /// space so blends look uniform).
    static func color(hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green:    CGFloat((hex >> 8) & 0xFF) / 255,
            blue:     CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }

    /// `[overlay].accent` parser used as the user-override path
    /// over the theme's accent. `PerchConfig` already drops malformed
    /// values, so a parse failure here means the user explicitly set
    /// "system" — return nil so the theme accent wins.
    private static func parseAccent(_ s: String) -> NSColor? {
        if s == "system" { return nil }
        var t = s
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let v = UInt32(t, radix: 16) else {
            return nil
        }
        return color(hex: v, alpha: 1)
    }

    /// Map `ThemeFont` → an AppKit font instance. Mono uses
    /// monospacedSystemFont (the existing default), rounded asks
    /// NSFontDescriptor for `.rounded` design, system is the
    /// default system font. Falls back to mono on any descriptor
    /// failure so a misconfigured environment never breaks layout.
    /// Module-internal so `OverlayCanvas.pillRect(...)` sizes the
    /// pill width with the same font family the painter will use.
    static func labelFont(_ kind: ThemeFont, size: Double) -> NSFont {
        let pt = CGFloat(size)
        switch kind {
        case .mono:
            return NSFont.monospacedSystemFont(ofSize: pt, weight: .semibold)
        case .system:
            return NSFont.systemFont(ofSize: pt, weight: .semibold)
        case .rounded:
            let base = NSFont.systemFont(ofSize: pt, weight: .semibold)
            let desc = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
            return NSFont(descriptor: desc, size: pt) ?? base
        }
    }
}

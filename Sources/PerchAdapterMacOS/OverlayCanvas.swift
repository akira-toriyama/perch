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

/// Where the pill anchors relative to its `hint.element.frame`.
/// Hint mode anchors at the element's top-left (so the label sits
/// over the clickable target's corner — Vimium convention); grid
/// mode anchors at the frame's center (the cell mid-point) because
/// the frame is the cell rect, not a clickable target.
enum PillPlacement {
    case elementTopLeft
    case elementCenter
}

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
    private let placement: PillPlacement
    private let particleDriver: ParticleDriver
    private let ghostDriver: GhostDriver
    private var pills: [PillLayout] = []

    /// Bundle id of the app the controller resolved as frontmost
    /// when hint mode entered. Used by `effectiveAppearEffect` /
    /// `effectiveMatchEffect` / ... lookups so a per-app override
    /// (e.g. `[behavior."com.figma.Desktop"] match-effect = "none"`)
    /// wins over the global default. nil for app-agnostic modes
    /// (grid / search) — lookups then return the global default.
    var activeBundleID: String?

    /// Per-app overlay-effect lookups. Each consults
    /// `behavior.perApp[bundleID]` first and falls back to the
    /// global `[overlay.effect]` knob. Used by every effect-firing
    /// site so per-app overrides land transparently.
    func effectiveAppear() -> AppearEffect {
        config.behavior.effectiveAppearEffect(
            for: activeBundleID,
            fallback: config.effect.appear)
    }
    func effectiveMatch() -> MatchEffect {
        config.behavior.effectiveMatchEffect(
            for: activeBundleID,
            fallback: config.effect.match)
    }
    func effectiveUnmatch() -> UnmatchEffect {
        config.behavior.effectiveUnmatchEffect(
            for: activeBundleID,
            fallback: config.effect.unmatch)
    }
    func effectiveNarrow() -> MatchEffect {
        config.behavior.effectiveNarrowEffect(
            for: activeBundleID,
            fallback: config.effect.narrow)
    }
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

    init(
        frame frameRect: NSRect,
        config: PerchConfig,
        placement: PillPlacement = .elementTopLeft
    ) {
        self.config = config
        self.placement = placement
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
        self.particleDriver = ParticleDriver(painter: p)
        self.ghostDriver = GhostDriver(painter: p)

        super.init(frame: frameRect)
        wantsLayer = true
        if config.overlay.blurEnabled {
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
        let wasBlur = config.overlay.blurEnabled
        config = cfg
        painter.updateConfig(cfg)
        // Toggle blur subview in place when the knob flips.
        if cfg.overlay.blurEnabled != wasBlur {
            if cfg.overlay.blurEnabled {
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
    ///
    /// Diff against the previous pill set so any hints disappearing
    /// from the visible list (typed prefix no longer matches them)
    /// can play the configured `narrowEffect` exit animation. The
    /// diff is skipped on the first frame (nothing to compare to)
    /// and on the chord-wait "show only winner" present (we don't
    /// want every non-winner to fly off — the chord wait is short
    /// and the visual would be noisy).
    func present(hints: [Hint], typed: String) {
        let firstFrame = pills.isEmpty
        // Diff: which pills are about to disappear? We snapshot
        // BEFORE rebuilding `pills` so the ghost driver has the
        // correct rects. Skip the diff if narrowEffect is none —
        // saves the allocation + set build on the common path.
        var eliminated: [(Hint, CGRect)] = []
        if !firstFrame,
           config.overlay.animEnabled,
           effectiveNarrow() != .none {
            let newKeys = Set(hints.map { $0.keys })
            for old in pills where !newKeys.contains(old.hint.keys) {
                eliminated.append((old.hint, old.rect))
            }
        }

        self.typed = typed
        self.state = .idle
        let kind = config.overlay.animEnabled
            ? effectiveAppear().resolvingRandom() : .none
        pills = hints.enumerated().map { idx, h in
            // Cascade staggers entrance by pill index — 30ms per
            // pill is enough to read as "wave" without the last
            // pill arriving long after the user starts typing.
            // The scale is the per-pill duration AFTER the user's
            // `effectDurationScale`, so a 2× duration scale gives a
            // 2× cascade spread too.
            let perPillStagger: TimeInterval = 0.03 * config.effect.durationScale
            let delay: TimeInterval =
                kind == .cascade ? perPillStagger * TimeInterval(idx) : 0
            return PillLayout(
                hint: h,
                rect: pillRect(for: h),
                matched: !typed.isEmpty && h.keys.hasPrefix(typed),
                appearDelay: delay)
        }
        if firstFrame, config.overlay.animEnabled, kind != .none {
            appearedAt = CACurrentMediaTime()
        }
        layoutPills()

        if !eliminated.isEmpty {
            spawnGhosts(eliminated)
        }
    }

    /// Mark all currently-visible pills as "missed" — the user typed
    /// something we can't match. The painter draws them in red; a
    /// timer (owned by OverlayWindow) calls clear() after the
    /// flash duration. The unmatch motion (shake / fade) is layered
    /// in `animateUnmatch(_:)` after this call so the red recolor
    /// always lands first.
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

    /// Scale a baseline duration by the user's
    /// `[overlay.effect].duration-scale` (clamped 0.1..5.0 by the
    /// config parser, so this can't return absurd values). Every
    /// `let duration = ...` literal in this file routes through
    /// here so a single config knob controls the whole effect
    /// system's tempo.
    private func scaled(_ base: TimeInterval) -> TimeInterval {
        base * config.effect.durationScale
    }

    /// Run the configured `[overlay.effect].unmatch` motion over
    /// the standard 200ms flash window. `completion` fires when the
    /// animation finishes — OverlayWindow uses it to gate `hide()`
    /// so the pills don't vanish mid-shake.
    ///
    /// `.none` is a no-op (returns to the caller immediately after
    /// the 200ms flash). Every other kind runs over 200ms — the
    /// intensity scaler picks the spatial magnitude.
    func animateUnmatch(
        kind: UnmatchEffect,
        intensity: EffectIntensity,
        completion: @escaping () -> Void
    ) {
        let resolved = kind.resolvingRandom()
        switch resolved {
        case .none, .random:
            DispatchQueue.main.asyncAfter(deadline: .now() + scaled(0.2)) {
                MainActor.assumeIsolated { completion() }
            }
        case .shake:
            runShake(intensity: intensity, completion: completion)
        case .fade:
            runFade(intensity: intensity, completion: completion)
        case .drop:
            runTranslate(
                dx: 0, dy: 120 * intensity.scale,
                fadeToZero: true, duration: scaled(0.2),
                intensity: intensity, completion: completion)
        case .rise:
            runTranslate(
                dx: 0, dy: -120 * intensity.scale,
                fadeToZero: true, duration: scaled(0.2),
                intensity: intensity, completion: completion)
        case .slideLeft:
            runTranslate(
                dx: -160 * intensity.scale, dy: 0,
                fadeToZero: true, duration: scaled(0.2),
                intensity: intensity, completion: completion)
        case .slideRight:
            runTranslate(
                dx: 160 * intensity.scale, dy: 0,
                fadeToZero: true, duration: scaled(0.2),
                intensity: intensity, completion: completion)
        case .vibrate:
            runVibrate(intensity: intensity, completion: completion)
        case .fireworks:
            burstParticles(
                emission: .fireworks, target: .everyPill,
                intensity: intensity, duration: scaled(0.2),
                completion: completion)
        case .confetti:
            burstParticles(
                emission: .confetti, target: .everyPill,
                intensity: intensity, duration: scaled(0.2),
                completion: completion)
        }
    }

    /// 200ms horizontal shake with 3 oscillations. Amplitude is
    /// 4pt × intensity scale (subtle 2.4 → wild 10). Drives the
    /// painter's shared `setOffset(dx:dy:)` channel.
    private func runShake(
        intensity: EffectIntensity,
        completion: @escaping () -> Void
    ) {
        let duration = scaled(0.2)
        let amplitude: CGFloat = 4 * intensity.scale
        let start = CACurrentMediaTime()
        // Damped sine: amplitude × sin(2π × cycles × p) × (1 - p) so
        // the tail settles to 0 even if the timer slips a frame.
        func tick() {
            let elapsed = CACurrentMediaTime() - start
            let p = min(elapsed / duration, 1)
            let damp = 1 - p
            let dx = amplitude * CGFloat(sin(2 * .pi * 3 * p)) * CGFloat(damp)
            painter.setOffset(dx: dx, dy: 0)
            if p < 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
                    MainActor.assumeIsolated { tick() }
                }
            } else {
                painter.setOffset(dx: 0, dy: 0)
                completion()
            }
        }
        tick()
    }

    /// 200ms opacity fade applied through the painter's `pillsAlpha`
    /// channel. Same window as the red flash so the user sees
    /// red-during-fade rather than red-then-fade.
    private func runFade(
        intensity: EffectIntensity,
        completion: @escaping () -> Void
    ) {
        let duration = scaled(0.2)
        let start = CACurrentMediaTime()
        // Intensity reserved for future amplitude tuning — duration
        // is fixed because it's tied to the red-flash window.
        _ = intensity
        func tick() {
            let elapsed = CACurrentMediaTime() - start
            let p = min(elapsed / duration, 1)
            painter.setPillsAlpha(CGFloat(1 - p))
            if p < 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
                    MainActor.assumeIsolated { tick() }
                }
            } else {
                painter.setPillsAlpha(1)
                completion()
            }
        }
        tick()
    }

    /// Animate the winning (`resolved`) pill per `[overlay.effect]`
    /// match config, then call `completion`. Non-winning pills stay
    /// where they are visually — they'll be torn down by `hide()`
    /// once completion fires. AXPress dispatches in PARALLEL on the
    /// OverlayWindow side so the click isn't blocked by the
    /// animation — the user perceives the visual ack as riding on
    /// top of an already-firing press.
    ///
    /// `.none` is a no-op — completion fires synchronously so the
    /// existing snappy path is byte-for-byte identical.
    func animateMatch(
        winning: Hint,
        kind: MatchEffect,
        intensity: EffectIntensity,
        completion: @escaping () -> Void
    ) {
        let resolved = kind.resolvingRandom()
        switch resolved {
        case .none, .random:
            completion()
        case .fade:
            runMatchAnim(
                winning: winning,
                targetScale: 1.0,
                targetOpacity: 0.0,
                duration: scaled(0.12),
                completion: completion)
        case .explode:
            let s: CGFloat = 1 + 0.4 * intensity.scale
            runMatchAnim(
                winning: winning,
                targetScale: s,
                targetOpacity: 0.0,
                duration: scaled(0.14),
                completion: completion)
        case .drop:
            runMatchAnim(
                winning: winning,
                targetScale: 1.0,
                targetOpacity: 0.0,
                targetDx: 0,
                targetDy: 120 * intensity.scale,
                duration: scaled(0.18),
                completion: completion)
        case .rise:
            runMatchAnim(
                winning: winning,
                targetScale: 1.0,
                targetOpacity: 0.0,
                targetDx: 0,
                targetDy: -120 * intensity.scale,
                duration: scaled(0.18),
                completion: completion)
        case .slideLeft:
            runMatchAnim(
                winning: winning,
                targetScale: 1.0,
                targetOpacity: 0.0,
                targetDx: -160 * intensity.scale,
                targetDy: 0,
                duration: scaled(0.18),
                completion: completion)
        case .slideRight:
            runMatchAnim(
                winning: winning,
                targetScale: 1.0,
                targetOpacity: 0.0,
                targetDx: 160 * intensity.scale,
                targetDy: 0,
                duration: scaled(0.18),
                completion: completion)
        case .vibrate:
            runWinningVibrate(
                winning: winning, intensity: intensity,
                completion: completion)
        case .fireworks:
            // Burst from the winning pill's center, no per-pill
            // motion — the burst IS the ack.
            burstParticles(
                emission: .fireworks, target: .winningOnly(winning),
                intensity: intensity, duration: scaled(0.22),
                completion: completion)
        case .confetti:
            burstParticles(
                emission: .confetti, target: .winningOnly(winning),
                intensity: intensity, duration: scaled(0.22),
                completion: completion)
        }
    }

    /// Driver for the match animation on the WINNING pill. Lerps
    /// scale, opacity, and a (dx, dy) translation over `duration`
    /// with ease-out cubic. Resets painter state on completion so a
    /// follow-up enumeration (`.pressContinuous`) starts clean.
    private func runMatchAnim(
        winning: Hint,
        targetScale: CGFloat,
        targetOpacity: CGFloat,
        targetDx: CGFloat = 0,
        targetDy: CGFloat = 0,
        duration: TimeInterval,
        completion: @escaping () -> Void
    ) {
        let start = CACurrentMediaTime()
        func tick() {
            let elapsed = CACurrentMediaTime() - start
            let p = min(elapsed / duration, 1)
            let eased = 1 - pow(1 - p, 3)
            let lerp: (CGFloat, CGFloat) -> CGFloat = { from, to in
                from + (to - from) * CGFloat(eased)
            }
            painter.setMatchAnim(
                winningHintKeys: winning.keys,
                scale: lerp(1, targetScale),
                opacity: lerp(1, targetOpacity),
                dx: lerp(0, targetDx),
                dy: lerp(0, targetDy))
            if p < 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
                    MainActor.assumeIsolated { tick() }
                }
            } else {
                painter.setMatchAnim(
                    winningHintKeys: nil, scale: 1, opacity: 1)
                completion()
            }
        }
        tick()
    }

    /// All-pill translation driver shared by drop / rise / slide-*.
    /// Lerps the painter's `(dx, dy)` offset to the target while
    /// optionally fading `pillsAlpha` to 0 — so the pill doesn't
    /// linger as a visible card just outside its original frame.
    private func runTranslate(
        dx: CGFloat, dy: CGFloat,
        fadeToZero: Bool,
        duration: TimeInterval,
        intensity: EffectIntensity,
        completion: @escaping () -> Void
    ) {
        _ = intensity   // amplitude already baked into caller's dx/dy
        let start = CACurrentMediaTime()
        func tick() {
            let elapsed = CACurrentMediaTime() - start
            let p = min(elapsed / duration, 1)
            let eased = 1 - pow(1 - p, 3)
            painter.setOffset(
                dx: dx * CGFloat(eased), dy: dy * CGFloat(eased))
            if fadeToZero {
                painter.setPillsAlpha(1 - CGFloat(eased))
            }
            if p < 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
                    MainActor.assumeIsolated { tick() }
                }
            } else {
                painter.setOffset(dx: 0, dy: 0)
                painter.setPillsAlpha(1)
                completion()
            }
        }
        tick()
    }

    /// 2-D high-frequency in-place jitter — wand's `vibrate`. Same
    /// damped-sine envelope as `runShake` but on both axes with
    /// independent phases so the motion reads as buzzy rather than
    /// horizontal-sweep. Amplitude scaled by intensity.
    private func runVibrate(
        intensity: EffectIntensity,
        completion: @escaping () -> Void
    ) {
        let duration = scaled(0.2)
        let amp: CGFloat = 3 * intensity.scale
        let start = CACurrentMediaTime()
        func tick() {
            let elapsed = CACurrentMediaTime() - start
            let p = min(elapsed / duration, 1)
            let damp = 1 - p
            let dx = amp * CGFloat(sin(2 * .pi * 6 * p)) * CGFloat(damp)
            let dy = amp * CGFloat(cos(2 * .pi * 7 * p)) * CGFloat(damp)
            painter.setOffset(dx: dx, dy: dy)
            if p < 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
                    MainActor.assumeIsolated { tick() }
                }
            } else {
                painter.setOffset(dx: 0, dy: 0)
                completion()
            }
        }
        tick()
    }

    /// Winning-only vibrate variant for the `match` direction —
    /// applies the jitter via the match-anim channel so non-winning
    /// pills stay still while the resolve target buzzes.
    private func runWinningVibrate(
        winning: Hint,
        intensity: EffectIntensity,
        completion: @escaping () -> Void
    ) {
        let duration = scaled(0.2)
        let amp: CGFloat = 3 * intensity.scale
        let start = CACurrentMediaTime()
        func tick() {
            let elapsed = CACurrentMediaTime() - start
            let p = min(elapsed / duration, 1)
            let damp = 1 - p
            let dx = amp * CGFloat(sin(2 * .pi * 6 * p)) * CGFloat(damp)
            let dy = amp * CGFloat(cos(2 * .pi * 7 * p)) * CGFloat(damp)
            let alpha = max(0, 1 - CGFloat(p) * 0.6)
            painter.setMatchAnim(
                winningHintKeys: winning.keys,
                scale: 1, opacity: alpha,
                dx: dx, dy: dy)
            if p < 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
                    MainActor.assumeIsolated { tick() }
                }
            } else {
                painter.setMatchAnim(
                    winningHintKeys: nil, scale: 1, opacity: 1)
                completion()
            }
        }
        tick()
    }

    // MARK: - Effect-driver delegates

    /// Where a particle burst emits from. Match → winning pill;
    /// unmatch → every visible pill.
    private enum ParticleTarget {
        case winningOnly(Hint)
        case everyPill
    }

    /// Resolve the target into canvas-local emitter points + delegate
    /// to `ParticleDriver`. Centralises the pills-lookup so each
    /// `animateMatch`/`animateUnmatch` switch case stays one line.
    private func burstParticles(
        emission: ParticleEmission,
        target: ParticleTarget,
        intensity: EffectIntensity,
        duration: TimeInterval,
        completion: @escaping () -> Void
    ) {
        let emitters: [CGPoint]
        switch target {
        case .winningOnly(let h):
            if let r = pills.first(where: { $0.hint.keys == h.keys })?.rect {
                emitters = [CGPoint(x: r.midX, y: r.midY)]
            } else {
                emitters = []
            }
        case .everyPill:
            emitters = pills.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) }
        }
        let accent = HintPainter.resolvePalette(cfg: config).accentColor
        particleDriver.burst(
            from: emitters, emission: emission,
            intensity: intensity, accent: accent,
            duration: duration, completion: completion)
    }

    /// Spawn ghosts via the dedicated driver. Wrapping function
    /// applies the `narrow` effect kind from config + the scaled
    /// per-ghost duration; the driver handles simulation.
    private func spawnGhosts(_ eliminated: [(Hint, CGRect)]) {
        let resolved = effectiveNarrow().resolvingRandom()
        ghostDriver.spawn(
            eliminated: eliminated,
            kind: resolved,
            intensity: config.effect.intensity,
            duration: scaled(0.18))
    }

    /// Push the currently-held modifier flags into the painter so
    /// the modifier-badge corner glyph repaints. Called from the
    /// KeyTap's `onFlagsChanged` callback while the overlay is up.
    func setModifierFlags(_ flags: CGEventFlags) {
        painter.setModifierFlags(flags)
    }

    /// Start the border hue-cycle tick. Idempotent — calling while
    /// already running is a no-op. The tick runs at ~30Hz (smooth
    /// enough for a slow rotation, half the cost of 60Hz) and stops
    /// when `stopBorderCycle` is called or the overlay hides.
    func startBorderCycle() {
        guard config.border.effect != .off,
              config.border.cycleSeconds > 0,
              !borderCycleActive else { return }
        borderCycleActive = true
        borderCycleStart = CACurrentMediaTime()
        tickBorderCycle()
    }

    func stopBorderCycle() {
        borderCycleActive = false
        painter.setBorderHueOffset(0)
    }

    private var borderCycleActive = false
    private var borderCycleStart: TimeInterval = 0

    private func tickBorderCycle() {
        guard borderCycleActive else { return }
        let elapsed = CACurrentMediaTime() - borderCycleStart
        let period = max(0.1, config.border.cycleSeconds)
        let progress = (elapsed.truncatingRemainder(dividingBy: period)) / period
        painter.setBorderHueOffset(CGFloat(progress))
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) {
            [weak self] in
            MainActor.assumeIsolated { self?.tickBorderCycle() }
        }
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
        let font = HintPainter.labelFont(
            config.overlay.theme.palette().font, size: config.overlay.fontSize)
        let label = hint.keys.uppercased()
        let textW = (label as NSString).size(
            withAttributes: [.font: font]).width
        let w = ceil(textW) + Self.pillPadX * 2
        let h = ceil(font.boundingRectForFont.height) + Self.pillPadY * 2

        // Anchor point in CG coords (top-left for hint mode, center
        // for grid mode). The canvasLocal conversion is symmetric;
        // grid mode then shifts the pill origin back by half its
        // size so the pill is centered on the cell midpoint.
        let cgAnchor: CGPoint
        switch placement {
        case .elementTopLeft:
            cgAnchor = hint.element.frame.origin
        case .elementCenter:
            cgAnchor = CGPoint(
                x: hint.element.frame.midX,
                y: hint.element.frame.midY)
        }
        let local = OverlayCoords.canvasLocal(
            cg: cgAnchor,
            unionFrame: unionFrame,
            primaryHeight: primaryHeight)
        switch placement {
        case .elementTopLeft:
            return CGRect(x: local.x, y: local.y, width: w, height: h)
        case .elementCenter:
            return CGRect(
                x: local.x - w / 2, y: local.y - h / 2,
                width: w, height: h)
        }
    }

    /// Rebuild the blur mask path (so frost shows only behind pills)
    /// and refresh the painter. Called from `present`, `flashMiss`,
    /// and from itself while the entrance animation runs.
    ///
    /// Per-pill appear state is computed here and stored back into
    /// `pills` so the painter consumes the same numbers the mask
    /// transform uses — frost stays welded to each pill regardless
    /// of which `appearEffect` is active.
    ///
    /// Coordinate-system note: `pill.rect` is in canvas's flipped
    /// (top-left origin) coords. The blurView's `CAShapeLayer` mask
    /// uses Y-up from bottom-left because `NSVisualEffectView` is
    /// not flipped. Flip Y explicitly when crossing into the mask
    /// layer's coord system — skipping this surfaces as empty
    /// pill-shaped frost rectangles mirrored to the bottom of the
    /// canvas (PR #16).
    private func layoutPills() {
        // Compute per-pill appear state for this tick.
        let kind = config.overlay.animEnabled
            ? effectiveAppear().resolvingRandom() : .none
        let now = CACurrentMediaTime()
        var anyInFlight = false
        for i in pills.indices {
            let state = currentAppearState(
                kind: kind, pill: pills[i], now: now)
            pills[i].appearScale = state.scale
            pills[i].appearDx = state.dx
            pills[i].appearDy = state.dy
            pills[i].appearAlpha = state.alpha
            if state.inFlight { anyInFlight = true }
        }

        let canvasH = bounds.height
        if let mask = blurView.layer?.mask as? CAShapeLayer {
            let path = CGMutablePath()
            for p in pills {
                let unflipped = CGRect(
                    x: p.rect.minX,
                    y: canvasH - p.rect.maxY,
                    width: p.rect.width,
                    height: p.rect.height)
                // Mask transform respects per-pill scale + offset
                // so the frost moves in lockstep — without this,
                // a cascading pill paints its label inside an
                // empty frost rect at the final position.
                let t = transform(
                    for: unflipped,
                    scale: p.appearScale,
                    dx: p.appearDx,
                    dy: -p.appearDy)   // mask is Y-up
                path.addRoundedRect(
                    in: unflipped,
                    cornerWidth: Self.cornerRadius,
                    cornerHeight: Self.cornerRadius,
                    transform: t)
            }
            mask.path = path
        }
        // `scale` arg is the BACKWARD-COMPAT global scalar — kept
        // 1.0 because per-pill state is now in PillLayout. The
        // painter respects PillLayout.appearScale + the global
        // scale below for its own per-pill compose math.
        painter.update(
            pills: pills, typed: typed, state: state, scale: 1.0)

        if anyInFlight {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
                [weak self] in
                MainActor.assumeIsolated { self?.layoutPills() }
            }
        }
    }

    /// One pill's appear state at `now` — `(scale, dx, dy, alpha)`
    /// + `inFlight` flag telling `layoutPills` whether to schedule
    /// the next tick.
    private func currentAppearState(
        kind: AppearEffect,
        pill: PillLayout,
        now: TimeInterval
    ) -> (scale: CGFloat, dx: CGFloat, dy: CGFloat,
          alpha: CGFloat, inFlight: Bool) {
        guard let t0 = appearedAt, kind != .none else {
            return (1, 0, 0, 1, false)
        }
        let perPillDuration: TimeInterval = 0.15 * config.effect.durationScale
        let local = now - t0 - pill.appearDelay
        if local < 0 {
            // This cascading pill hasn't started yet — paint
            // hidden at the bloom-style scale so the entrance
            // reads as "arriving" rather than popping.
            return (0.4, 0, 0, 0, true)
        }
        let p = min(local / perPillDuration, 1)
        let eased = 1 - pow(1 - p, 3)
        let e = CGFloat(eased)
        let i = config.effect.intensity.scale
        let done = local >= perPillDuration
        switch kind {
        case .none, .random:
            return (1, 0, 0, 1, false)
        case .pop:
            // Historical scale-in 0.85 → 1.0.
            return (0.85 + 0.15 * e, 0, 0, 1, !done)
        case .cascade:
            // Per-pill bloom + fade-in chain. Each pill blooms
            // from 0.6 → 1.0 with alpha 0 → 1.
            return (0.6 + 0.4 * e, 0, 0, e, !done)
        case .fadeIn:
            return (1, 0, 0, e, !done)
        case .dropIn:
            // Pills fall from -40pt above to 0; alpha eases in.
            let dy = -40 * i * (1 - e)
            return (1, 0, dy, e, !done)
        case .bloom:
            // 0.4 → 1.0 scale + 0 → 1 alpha — explode in reverse.
            return (0.4 + 0.6 * e, 0, 0, e, !done)
        }
    }

    /// Build the per-pill mask transform (about the pill's centre)
    /// — composes scale + translate so the frost mask follows
    /// the same transform the painter uses for the pill body.
    private func transform(
        for rect: CGRect, scale: CGFloat, dx: CGFloat, dy: CGFloat
    ) -> CGAffineTransform {
        let cx = rect.midX, cy = rect.midY
        return CGAffineTransform(translationX: dx, y: dy)
            .translatedBy(x: cx, y: cy)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -cx, y: -cy)
    }

    /// Per-pill geometry + state. Recomputed every `present`. The
    /// appear-effect channel (scale/dx/dy/alpha) is per-pill so
    /// `.cascade` can stagger each pill independently — global
    /// scale-in (`.pop`) sets every pill to the same value each
    /// tick, but the storage shape is shared.
    /// `internal` rather than `fileprivate` so `HintPainter` (in
    /// its own file) can read the array via `update(pills:…)`.
    struct PillLayout {
        let hint: Hint
        let rect: CGRect
        var matched: Bool   // typed prefix matches this label
        /// Start offset (seconds) for this pill's appear animation
        /// inside the overall entrance window. `.cascade` uses a
        /// non-zero offset proportional to pill index; the other
        /// kinds leave it 0 so all pills animate in lockstep.
        var appearDelay: TimeInterval = 0
        /// Live appear-state — driven by `layoutPills` each tick
        /// while the entrance window is active.
        var appearScale: CGFloat = 1
        var appearDx: CGFloat = 0
        var appearDy: CGFloat = 0
        var appearAlpha: CGFloat = 1
    }
}

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
           config.overlayAnimEnabled,
           config.narrowEffect != .none {
            let newKeys = Set(hints.map { $0.keys })
            for old in pills where !newKeys.contains(old.hint.keys) {
                eliminated.append((old.hint, old.rect))
            }
        }

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
        base * config.effectDurationScale
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
            runParticles(
                emission: .fireworks, target: .everyPill,
                intensity: intensity, duration: scaled(0.2),
                completion: completion)
        case .confetti:
            runParticles(
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
            runParticles(
                emission: .fireworks, target: .winningOnly(winning),
                intensity: intensity, duration: scaled(0.22),
                completion: completion)
        case .confetti:
            runParticles(
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

    // MARK: - Ghost (narrow-effect) driver

    /// Per-ghost simulation state. Spawned when `present(...)`
    /// detects a pill leaving the visible set; advanced by
    /// `tickGhosts` until `progress >= 1` at which point the ghost
    /// is removed from the list. Multiple spawns can be in-flight
    /// simultaneously (the user typing two letters in quick
    /// succession before the first ghost's animation finishes),
    /// each independent with its own `start` time.
    private struct LiveGhost {
        let hint: Hint
        let baseRect: CGRect
        let kind: MatchEffect             // resolved (no `.random`)
        let intensity: EffectIntensity
        let start: TimeInterval
        let duration: TimeInterval
        var scale: CGFloat = 1
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var alpha: CGFloat = 1
    }
    private var liveGhosts: [LiveGhost] = []
    private var ghostTickActive = false

    /// Spawn one ghost per eliminated pill, then start the global
    /// tick if it's not already running. Re-resolving `.random` per
    /// spawn means each spawn batch picks its own concrete kind —
    /// so typing the same letter twice can show two different
    /// effects, matching the `match.random` UX.
    private func spawnGhosts(_ eliminated: [(Hint, CGRect)]) {
        let resolved = config.narrowEffect.resolvingRandom()
        guard resolved != .none else { return }
        let now = CACurrentMediaTime()
        // Particle effects (fireworks / confetti) on every
        // eliminated pill would emit hundreds of particles when
        // the user types the first letter of a label set with many
        // non-matching pills. Cap by falling back to `.fade` for
        // those kinds in the narrow context — same visual idiom
        // (something is going away), without the CPU cost.
        let safe: MatchEffect =
            (resolved == .fireworks || resolved == .confetti)
                ? .fade : resolved
        for (h, r) in eliminated {
            liveGhosts.append(LiveGhost(
                hint: h, baseRect: r, kind: safe,
                intensity: config.effectIntensity,
                start: now, duration: scaled(0.18)))
        }
        publishGhosts()
        if !ghostTickActive {
            ghostTickActive = true
            tickGhosts()
        }
    }

    /// Advance every live ghost. Removes any whose progress has
    /// reached 1.0 and stops the tick when the list empties. Runs
    /// at ~60Hz only while ghosts are alive — idle CPU is 0.
    private func tickGhosts() {
        let now = CACurrentMediaTime()
        var next: [LiveGhost] = []
        next.reserveCapacity(liveGhosts.count)
        for var g in liveGhosts {
            let p = (now - g.start) / g.duration
            if p >= 1 { continue }   // animation done; drop ghost
            updateGhost(&g, p: p)
            next.append(g)
        }
        liveGhosts = next
        publishGhosts()
        if liveGhosts.isEmpty {
            ghostTickActive = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
            [weak self] in
            MainActor.assumeIsolated { self?.tickGhosts() }
        }
    }

    /// Compute the per-ghost (scale, dx, dy, alpha) for the given
    /// normalised progress 0..1. Effect kinds re-use the match-
    /// effect amplitude formulas so the visual reads consistently:
    /// a `.drop` ghost falls the same distance a `.drop` match
    /// would. Ease-out cubic on the bulk of them so the ghost
    /// starts fast and settles.
    private func updateGhost(_ g: inout LiveGhost, p: TimeInterval) {
        let eased = 1 - pow(1 - p, 3)
        let e = CGFloat(eased)
        let i = g.intensity.scale
        switch g.kind {
        case .none, .random:
            break
        case .fade:
            g.alpha = 1 - e
        case .explode:
            g.scale = 1 + (0.4 * i) * e
            g.alpha = 1 - e
        case .drop:
            g.dy = (120 * i) * e
            g.alpha = 1 - e
        case .rise:
            g.dy = -(120 * i) * e
            g.alpha = 1 - e
        case .slideLeft:
            g.dx = -(160 * i) * e
            g.alpha = 1 - e
        case .slideRight:
            g.dx = (160 * i) * e
            g.alpha = 1 - e
        case .vibrate:
            let amp: CGFloat = 3 * i
            let damp = 1 - p
            g.dx = amp * CGFloat(sin(2 * .pi * 6 * p)) * CGFloat(damp)
            g.dy = amp * CGFloat(cos(2 * .pi * 7 * p)) * CGFloat(damp)
            g.alpha = max(0, 1 - CGFloat(p) * 0.6)
        case .fireworks, .confetti:
            // `spawnGhosts` already downgraded these to `.fade`
            // for the narrow context; this case is defensive.
            g.alpha = 1 - e
        }
    }

    /// Push the current ghost state into the painter for the next
    /// redraw. Adapter layer maps the simulation struct → the
    /// painter's render struct (HintPainter.Ghost).
    private func publishGhosts() {
        painter.setGhosts(liveGhosts.map {
            HintPainter.Ghost(
                hint: $0.hint, baseRect: $0.baseRect,
                scale: $0.scale, dx: $0.dx, dy: $0.dy,
                alpha: $0.alpha)
        })
    }

    // MARK: - Particle drivers

    /// Particle emission pattern. `fireworks` shoots radially outward
    /// from each emission point with light gravity; `confetti` emits
    /// laterally with stronger downward gravity so it "rains" past
    /// the pill.
    private enum ParticleEmission { case fireworks, confetti }

    /// Which pills the particles emit from. Match → winning only;
    /// unmatch → every visible pill (the whole miss-feedback set).
    private enum ParticleTarget {
        case winningOnly(Hint)
        case everyPill
    }

    /// Per-particle simulation state — extends the painter's render
    /// struct with velocity + a base color so the driver can advance
    /// the system each tick without re-allocating the list.
    private struct LiveParticle {
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat
        var vy: CGFloat
        var radius: CGFloat
        var color: NSColor
        var alpha: CGFloat
    }

    /// Spawn + simulate particles across `duration`, calling
    /// `completion` when the burst fades out. Intensity scales the
    /// PER-EMISSION particle count + the initial velocity magnitude.
    private func runParticles(
        emission: ParticleEmission,
        target: ParticleTarget,
        intensity: EffectIntensity,
        duration: TimeInterval,
        completion: @escaping () -> Void
    ) {
        let palette = HintPainter.resolvePalette(cfg: config)
        let accent = palette.accentColor
        let extra: [NSColor] = [
            HintPainter.color(hex: 0xFFD700, alpha: 1),  // gold
            HintPainter.color(hex: 0xFF6EC7, alpha: 1),  // pink
            HintPainter.color(hex: 0x00E5FF, alpha: 1),  // cyan
            accent,
        ]
        var emitters: [CGPoint] = []
        switch target {
        case .winningOnly(let h):
            if let r = pills.first(where: { $0.hint.keys == h.keys })?.rect {
                emitters.append(CGPoint(x: r.midX, y: r.midY))
            }
        case .everyPill:
            emitters = pills.map { CGPoint(x: $0.rect.midX, y: $0.rect.midY) }
        }
        // Per-emitter particle count. Scale up with intensity but
        // hard-cap so an .everyPill burst on a 60-pill screen doesn't
        // spawn 600 simultaneous particles.
        let baseCount = emission == .fireworks ? 14 : 18
        let perEmitter = max(4, min(30, Int(CGFloat(baseCount) * intensity.scale)))
        var live: [LiveParticle] = []
        live.reserveCapacity(emitters.count * perEmitter)
        for emit in emitters {
            for _ in 0..<perEmitter {
                let v = emission == .fireworks
                    ? randomFireworkVelocity(intensity: intensity)
                    : randomConfettiVelocity(intensity: intensity)
                live.append(LiveParticle(
                    x: emit.x, y: emit.y,
                    vx: v.dx, vy: v.dy,
                    radius: CGFloat.random(in: 1.5...3.0),
                    color: extra.randomElement() ?? accent,
                    alpha: 1))
            }
        }
        // Gravity (canvas-flipped: positive y = downward = falling).
        let gravity: CGFloat = emission == .confetti ? 900 : 360
        let start = CACurrentMediaTime()
        var prev = start
        func tick() {
            let now = CACurrentMediaTime()
            let dt = CGFloat(now - prev)
            prev = now
            let p = min((now - start) / duration, 1)
            // Advance simulation.
            for i in live.indices {
                live[i].vy += gravity * dt
                live[i].x += live[i].vx * dt
                live[i].y += live[i].vy * dt
                // Linear alpha fade across the burst window. Easeout
                // would feel laggy at this duration; linear reads as
                // "tail dimming" which is what particles do IRL.
                live[i].alpha = max(0, 1 - CGFloat(p))
            }
            painter.setParticles(live.map {
                HintPainter.Particle(
                    x: $0.x, y: $0.y, radius: $0.radius,
                    color: $0.color, alpha: $0.alpha)
            })
            if p < 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
                    MainActor.assumeIsolated { tick() }
                }
            } else {
                painter.setParticles([])
                completion()
            }
        }
        tick()
    }

    /// Random radial velocity for a fireworks particle. Angle is
    /// uniform over the full circle; speed scales with intensity.
    private func randomFireworkVelocity(
        intensity: EffectIntensity
    ) -> CGVector {
        let angle = CGFloat.random(in: 0...(2 * .pi))
        let speed = CGFloat.random(in: 120...260) * intensity.scale
        return CGVector(
            dx: cos(angle) * speed,
            dy: sin(angle) * speed)
    }

    /// Confetti emits mostly downward with horizontal spread.
    private func randomConfettiVelocity(
        intensity: EffectIntensity
    ) -> CGVector {
        let dx = CGFloat.random(in: -120...120) * intensity.scale
        let dy = CGFloat.random(in: 20...160) * intensity.scale
        return CGVector(dx: dx, dy: dy)
    }

    /// Push the currently-held modifier flags into the painter so
    /// the modifier-badge corner glyph repaints. Called from the
    /// KeyTap's `onFlagsChanged` callback while the overlay is up.
    func setModifierFlags(_ flags: CGEventFlags) {
        painter.setModifierFlags(flags)
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
            config.overlayTheme.palette().font, size: config.overlayFontSize)
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

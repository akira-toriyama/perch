// Ghost-pill simulation for the `narrow` effect — a previously-
// visible pill that's been filtered out by the typed prefix gets an
// animated "exit" at its original rect.
//
// Each ghost owns its own start time + duration so multiple bursts
// can be in-flight simultaneously (the user typing two letters in
// quick succession before the first ghost's animation finishes).
// The driver advances them all on one global tick and removes any
// whose progress has reached 1.0.
//
// Originally inline in OverlayCanvas; extracted in PR #90 alongside
// `ParticleDriver`. No behaviour change.

import AppKit
import CoreGraphics
import Foundation
import PerchCore

@MainActor
final class GhostDriver {

    private weak var painter: HintPainter?
    private var live: [LiveGhost] = []
    private var tickActive = false

    init(painter: HintPainter) {
        self.painter = painter
    }

    /// Spawn one ghost per eliminated pill. `kind` is the
    /// pre-resolved match-effect kind (caller has already turned
    /// `.random` into a concrete case). Particle effects
    /// (`.fireworks` / `.confetti`) downgrade to `.fade` here — a
    /// particle burst per eliminated pill quickly turns into
    /// hundreds of simultaneous particles on a dense hint set.
    func spawn(
        eliminated: [(hint: Hint, rect: CGRect)],
        kind: MatchEffect,
        intensity: EffectIntensity,
        duration: TimeInterval
    ) {
        // Particle kinds (fireworks / confetti) downgrade to .fade
        // for the narrow context — see Config.parseEffect for the
        // user-facing warning. Per-event logging would spam.
        let safe: MatchEffect =
            (kind == .fireworks || kind == .confetti) ? .fade : kind
        guard safe != .none, safe != .random else { return }
        let now = CACurrentMediaTime()
        for (h, r) in eliminated {
            live.append(LiveGhost(
                hint: h, baseRect: r, kind: safe,
                intensity: intensity,
                start: now, duration: duration))
        }
        publish()
        if !tickActive {
            tickActive = true
            tick()
        }
    }

    private func tick() {
        guard let painter else { tickActive = false; return }
        let now = CACurrentMediaTime()
        var next: [LiveGhost] = []
        next.reserveCapacity(live.count)
        for var g in live {
            let p = (now - g.start) / g.duration
            if p >= 1 { continue }
            Self.update(&g, p: p)
            next.append(g)
        }
        live = next
        painter.setGhosts(live.map {
            HintPainter.Ghost(
                hint: $0.hint, baseRect: $0.baseRect,
                scale: $0.scale, dx: $0.dx, dy: $0.dy,
                alpha: $0.alpha)
        })
        if live.isEmpty {
            tickActive = false
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) {
            [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    /// Push the current ghost state into the painter without
    /// running the simulation forward — used right after spawn so
    /// the first frame paints immediately.
    private func publish() {
        painter?.setGhosts(live.map {
            HintPainter.Ghost(
                hint: $0.hint, baseRect: $0.baseRect,
                scale: $0.scale, dx: $0.dx, dy: $0.dy,
                alpha: $0.alpha)
        })
    }

    /// Per-effect amplitude formulas. Identical to the match-effect
    /// driver's per-frame math so a `.drop` ghost falls the same
    /// distance a `.drop` match would.
    private static func update(_ g: inout LiveGhost, p: TimeInterval) {
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
            // `spawn` already downgraded these to `.fade` for the
            // narrow context; defensive fallback.
            g.alpha = 1 - e
        }
    }

    /// Per-ghost simulation state.
    private struct LiveGhost {
        let hint: Hint
        let baseRect: CGRect
        let kind: MatchEffect
        let intensity: EffectIntensity
        let start: TimeInterval
        let duration: TimeInterval
        var scale: CGFloat = 1
        var dx: CGFloat = 0
        var dy: CGFloat = 0
        var alpha: CGFloat = 1
    }
}

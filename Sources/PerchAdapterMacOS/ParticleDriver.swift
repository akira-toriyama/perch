// Particle simulation for fireworks / confetti effects.
//
// Spawn a burst from one or more emitter points, simulate velocity +
// gravity + alpha decay over a fixed duration, push the render state
// to `HintPainter.setParticles(_:)` each tick. The painter is a pure
// renderer — all simulation lives here so the driver can be unit-
// tested without AppKit.
//
// Originally an inline section of OverlayCanvas; extracted in PR #90
// so OverlayCanvas can focus on layout + the canonical present()/clear()
// flow. No behaviour change.

import AppKit
import CoreGraphics
import Foundation
import PerchCore

/// Particle emission pattern.
public enum ParticleEmission: Sendable {
    /// Radial outward burst with light gravity (~360 px/s²).
    case fireworks
    /// Lateral spread with strong downward gravity (~900 px/s²)
    /// so particles "rain" past the pill.
    case confetti
}

@MainActor
final class ParticleDriver {

    private weak var painter: HintPainter?

    init(painter: HintPainter) {
        self.painter = painter
    }

    /// Spawn + simulate particles from each emitter for `duration`
    /// seconds. `accent` tints a quarter of the particles; the rest
    /// cycle through a fixed gold/pink/cyan palette for visual
    /// variety. `completion` fires on the next runloop tick after
    /// the burst finishes.
    func burst(
        from emitters: [CGPoint],
        emission: ParticleEmission,
        intensity: EffectIntensity,
        accent: NSColor,
        duration: TimeInterval,
        completion: @escaping () -> Void
    ) {
        guard let painter else { completion(); return }
        let colors: [NSColor] = [
            Self.color(hex: 0xFFD700, alpha: 1),    // gold
            Self.color(hex: 0xFF6EC7, alpha: 1),    // pink
            Self.color(hex: 0x00E5FF, alpha: 1),    // cyan
            accent,
        ]
        // Per-emitter particle count. Scale with intensity but
        // hard-cap so an .everyPill burst on a 60-pill screen
        // doesn't spawn 600 simultaneous particles.
        let baseCount = emission == .fireworks ? 14 : 18
        let perEmitter = max(4, min(30,
            Int(CGFloat(baseCount) * intensity.scale)))
        var live: [LiveParticle] = []
        live.reserveCapacity(emitters.count * perEmitter)
        for emit in emitters {
            for _ in 0..<perEmitter {
                let v = emission == .fireworks
                    ? Self.randomFireworkVelocity(intensity: intensity)
                    : Self.randomConfettiVelocity(intensity: intensity)
                live.append(LiveParticle(
                    x: emit.x, y: emit.y,
                    vx: v.dx, vy: v.dy,
                    radius: CGFloat.random(in: 1.5...3.0),
                    color: colors.randomElement() ?? accent,
                    alpha: 1))
            }
        }
        // Gravity (canvas-flipped: positive y = downward).
        let gravity: CGFloat = emission == .confetti ? 900 : 360
        let start = CACurrentMediaTime()
        var prev = start
        func tick() {
            guard let painter = self.painter else {
                completion(); return
            }
            let now = CACurrentMediaTime()
            let dt = CGFloat(now - prev)
            prev = now
            let p = min((now - start) / duration, 1)
            for i in live.indices {
                live[i].vy += gravity * dt
                live[i].x += live[i].vx * dt
                live[i].y += live[i].vy * dt
                // Linear fade — easeout reads as laggy at this
                // duration; linear is "tail dimming", what
                // particles do IRL.
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

    // MARK: - Per-particle state

    /// Live simulation state. Extends `HintPainter.Particle` with
    /// velocity so the driver can advance the system each tick
    /// without re-allocating the list.
    private struct LiveParticle {
        var x: CGFloat
        var y: CGFloat
        var vx: CGFloat
        var vy: CGFloat
        var radius: CGFloat
        var color: NSColor
        var alpha: CGFloat
    }

    // MARK: - Velocity helpers

    /// Uniform random angle, 120-260 px/s speed × intensity.
    private static func randomFireworkVelocity(
        intensity: EffectIntensity
    ) -> CGVector {
        let angle = CGFloat.random(in: 0...(2 * .pi))
        let speed = CGFloat.random(in: 120...260) * intensity.scale
        return CGVector(
            dx: cos(angle) * speed,
            dy: sin(angle) * speed)
    }

    /// Mostly downward with horizontal spread — emulates falling
    /// paper confetti.
    private static func randomConfettiVelocity(
        intensity: EffectIntensity
    ) -> CGVector {
        let dx = CGFloat.random(in: -120...120) * intensity.scale
        let dy = CGFloat.random(in: 20...160) * intensity.scale
        return CGVector(dx: dx, dy: dy)
    }

    /// 0xRRGGBB int → NSColor (sRGB). Duplicated from HintPainter
    /// to keep this file independent.
    private static func color(hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green:    CGFloat((hex >> 8) & 0xFF) / 255,
            blue:     CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }
}

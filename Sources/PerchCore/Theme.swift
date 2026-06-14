// Theme bridge + pill/effect vocabulary.
//
// The STATIC palette catalog (the `terminal` / `dracula` / `gruvbox` /
// … presets, their primary / foreground / background / font) now lives
// in the shared `sill` library (plan atelier's north star: "facet の
// theme 真似て" never said twice). perch consumes only sill's pure,
// AppKit-free `Palette` module — `ThemeSpec`, `paletteFor`, `FontKind`,
// `canonicalThemeNames` — and is the family's "pure twin", proving the
// pure layer is reusable by a non-facet Core.
//
// What stays perch-side here:
//   * the THEME-NAME bridge (`perchThemeSpec` / `perchCanonicalThemeName`)
//     that adapts sill's spec to perch's pill — adding the one
//     app-specific overlay sill deliberately omits: the frosted-pill
//     translucency (`perchPillAlpha`), plus perch's own dark-pill
//     `system` spec;
//   * the pill geometry (`PillShape`) and the transient hint-overlay
//     effects (`MatchEffect` / `UnmatchEffect` / `AppearEffect` /
//     `BorderEffect`) and the modifier-badge style — none of which are
//     shared theming atoms. (`EffectIntensity` is sill's shared knob
//     since 0.6.x adoption — typealiased below with a CGFloat `scale`
//     shim.)
//
// Stays in Core (no AppKit / CoreGraphics colors): the parsed config
// carries `ThemeSpec` + the enums across the seam; the Adapter
// (HintPainter) resolves them into NSColors at draw time.

import CoreGraphics
import Foundation
import Palette

// MARK: - Theme name → ThemeSpec (sill bridge)

/// Pill-background opacity perch paints behind the hint glyphs. This is
/// perch's app-specific pill-surface treatment (the frosted translucent
/// pill), NOT part of the shared `sill` palette — sill's `ThemeSpec`s
/// leave `backgroundAlpha` nil because facet's panels are opaque. Light
/// themes ride higher (the pale fill would wash out under the frost
/// otherwise); dark themes keep the historical 0.30. Derived from sill's
/// `isLight` luminance test (background brightness) rather than a
/// theme-name list, so new catalog light themes (`github-light` /
/// `catppuccin-latte`, …) are handled automatically — no perch-local
/// theme-name list to drift out of sync with sill (atelier north star).
public func perchPillAlpha(for spec: ThemeSpec) -> Double {
    spec.isLight ? 0.85 : 0.30
}

/// Fallback pill background for the `system` theme. sill's `system`
/// `ThemeSpec` carries `background == nil` (vibrancy fall-through for
/// facet's adaptive panel); perch's pill is a dark frosted chip
/// regardless of the macOS appearance, so it needs a concrete fill.
/// Black at the default translucency = the historical perch `system`
/// look.
public let perchSystemPillBgHex: UInt32 = 0x000000

/// perch's `system` theme spec. NOT sill's `system` preset (an adaptive
/// vibrancy panel with `background == nil` + dynamic label colors):
/// perch's surface is a dark translucent pill that does NOT flip with
/// the OS appearance, so it keeps white text on a black fill and only
/// borrows the OS control-accent via the `primary` sentinel (0). This is
/// the legitimate "bg は app 別" surface difference between facet's panel
/// and perch's pill (atelier Q6: the dark pill stays a divergence; the
/// concrete black `background` auto-derives `backgroundMode == .fixed`).
/// `muted` is a placeholder — perch never reads it.
public let perchSystemSpec = ThemeSpec(
    background: HexColor(perchSystemPillBgHex),
    foreground: HexColor(0xFFFFFF),
    muted: HexColor(0xFFFFFF),
    primary: HexColor(systemPrimarySentinel),
    font: .system,
    error: HexColor(defaultErrorHex),
    backgroundAlpha: 0.30)   // dark pill → the historical default frost

/// Resolve a canonical theme name into the `ThemeSpec` perch renders:
/// sill's authoritative palette plus perch's one app-specific overlay,
/// the frosted-pill translucency (`backgroundAlpha`). `system` returns
/// perch's own dark-pill spec. The name is assumed already canonical
/// (validated + `random`-resolved at config parse via
/// `perchCanonicalThemeName`); an unknown name falls through to sill's
/// `paletteFor`, which clamps to `terminal`.
public func perchThemeSpec(_ name: String) -> ThemeSpec {
    let n = name.lowercased()
    if n == "system" { return perchSystemSpec }
    var spec = paletteFor(n)                    // sill canonical palette
    spec.backgroundAlpha = perchPillAlpha(for: spec)  // perch frost overlay
    return spec
}

/// Validate a raw `[overlay].theme` / `overlay --theme ''` value against sill's
/// `canonicalThemeNames`, returning the canonical name or `nil` for an
/// unknown name so the caller can clamp to `system` + log (perch's
/// loud-typo-rejection discipline — sill's `paletteFor` is silent and
/// would mask a typo as `terminal`). `random` resolves HERE to a
/// concrete name (excluding `system` / `random`) so the chosen theme is
/// stable for the session; `system` and the built-ins pass through.
public func perchCanonicalThemeName(_ raw: String) -> String? {
    let t = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if t.isEmpty { return nil }
    if t == "random" {
        let pool = canonicalThemeNames.filter { $0 != "random" && $0 != "system" }
        return pool.randomElement() ?? "terminal"
    }
    // Membership + normalization delegate to sill's shared mechanism
    // (`random` was intercepted above, so its passthrough is unreachable).
    return canonical(t)
}

/// "Did you mean" hint for an unknown theme name — sill's `suggest(_:)`
/// surfaced through PerchCore so PerchApp (which doesn't link Palette)
/// can enrich its loud CLI reject. `nil` when nothing is close enough.
public func perchThemeNameSuggestion(_ raw: String) -> String? { suggest(raw) }

// MARK: - Modifier badge

/// What the modifier-badge corner annotation shows when a modifier
/// is held during hint mode.
///   - `.off` — no badge at all
///   - `.glyph` — `⌃⌥⇧⌘` Apple-canonical glyphs (the historical
///     behaviour; off-but-with-modifier renders as `⌘`, `⇧`, etc.)
///   - `.action` — glyph + a short action verb (`⌘ Copy`, `⇧ Right`,
///     `⌥ Focus`, `⌘⇧ Chain`) so the user reads exactly what the
///     resolve will do
public enum ModifierBadgeStyle: String, Sendable, CaseIterable {
    case off
    case glyph
    case action

    /// Parse with bool tolerance — older configs used
    /// `show-modifier-badge = true` / `false`; map those to `.glyph`
    /// / `.off`. Unknown strings clamp to `.off`.
    public static func parse(_ s: String) -> ModifierBadgeStyle? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        switch t {
        case "true", "1", "yes", "on": return .glyph
        case "false", "0", "no":       return .off
        default: return ModifierBadgeStyle(rawValue: t)
        }
    }
}

/// Pill geometry preset. The historical perch shape is `.pill`
/// (10pt rounded rect); the alternates let users dial visual
/// density up or down without changing the theme palette.
///
/// `.underline` is an outlier — no rounded body, just an
/// accent-colored bar under the label. Useful on light themes
/// where a filled pill reads as noise.
///
/// `.circle` is best for single-character labels (the natural
/// case at the top of perch's alphabet). The painter falls back
/// to `.pill` for 2+ char labels so geometry never crops the text.
public enum PillShape: String, Sendable, CaseIterable {
    case pill                 // 10pt rounded rect — historical default
    case square               // sharp-corner rect (1pt corner)
    case circle               // 1-char only; falls back to .pill for 2+
    case underline            // bar under text, no body
    case tag = "tag"          // pill + small triangle pointing at element

    public static func parse(_ s: String) -> PillShape? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return PillShape(rawValue: t)
    }
}

// MARK: - Effects

/// What perch does to the resolving (winning) pill on hint match.
/// Mirrors wand's `[gesture.effect] match` vocabulary verbatim,
/// scoped to perch's single-pill resolve target. Only the WINNING
/// pill animates — the rest dismiss immediately so the existing
/// snappy UX is preserved.
///
/// `intensity` (see `EffectIntensity`) multiplies the effect's
/// magnitude (scale / shake distance / particle count) but does
/// **not** lengthen the duration — perch's UX guidance is "AXPress
/// fires within ~150ms of the resolve" and the effect rides on top
/// of that window.
public enum MatchEffect: String, Sendable, CaseIterable {
    /// Default — pill vanishes the instant the hint resolves.
    case off
    /// Pill fades to alpha 0 over 120ms.
    case fade
    /// Pill scales 1.0 → ~1.4 and fades simultaneously over 140ms.
    case explode
    /// Pill translates downward off-screen while fading.
    case drop
    /// Pill translates upward off-screen while fading.
    case rise
    /// Pill slides out to the left while fading.
    case slideLeft = "slide-left"
    /// Pill slides out to the right while fading.
    case slideRight = "slide-right"
    /// Pill jitters in place (small high-frequency 2-D shake) and
    /// fades — same vocabulary as wand's `vibrate` (distinct from
    /// `unmatch.shake`, which is horizontal-only over the red flash).
    case vibrate
    /// Particle burst from the pill center radiating outward with
    /// gravity. Most attention-grabbing — natural on `match` since
    /// it's the moment the resolve actually fires.
    case fireworks
    /// Particles rain down past the pill with gravity. Same particle
    /// engine as `fireworks`, different emission pattern.
    case confetti
    /// Pick a random non-`none` non-`random` kind each resolve.
    case random

    public static func parse(_ s: String) -> MatchEffect? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return MatchEffect(rawValue: t)
    }

    /// Resolve `.random` to a concrete kind. Excludes `.off` (so
    /// random never collapses to no animation) and `.random` itself.
    /// Other cases pass through unchanged.
    public func resolvingRandom() -> MatchEffect {
        guard self == .random else { return self }
        let pool = MatchEffect.allCases.filter { $0 != .random && $0 != .off }
        return pool.randomElement() ?? .fade
    }
}

/// What perch does when the user types a key that doesn't match
/// any visible label, or hits a non-letter key. The existing 200ms
/// **red flash** is the baseline — `unmatch` layers an additional
/// motion on top so the user FEELS the miss (motion is faster to
/// process than color).
public enum UnmatchEffect: String, Sendable, CaseIterable {
    case off
    /// Pills shake horizontally ±4pt over 200ms (3 oscillations).
    case shake
    /// Pills fade out during the 200ms window.
    case fade
    /// Pills drop downward off-screen while fading.
    case drop
    /// Pills float upward while fading.
    case rise
    /// Pills slide out to the left while fading.
    case slideLeft = "slide-left"
    /// Pills slide out to the right while fading.
    case slideRight = "slide-right"
    /// Pills jitter in place (2-D shake distinct from horizontal
    /// `shake`) — wand's `vibrate` vocabulary.
    case vibrate
    /// Particle burst from each pill's center.
    case fireworks
    /// Particles rain past each pill with gravity.
    case confetti
    /// Pick a random non-`none` non-`random` kind each miss.
    case random

    public static func parse(_ s: String) -> UnmatchEffect? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return UnmatchEffect(rawValue: t)
    }

    public func resolvingRandom() -> UnmatchEffect {
        guard self == .random else { return self }
        let pool = UnmatchEffect.allCases.filter { $0 != .random && $0 != .off }
        return pool.randomElement() ?? .shake
    }
}

/// Entrance animation for the hint pills — symmetric with
/// `MatchEffect` / `UnmatchEffect` / `narrowEffect`, but fires
/// when the overlay APPEARS rather than disappears. The kind
/// vocabulary intentionally mirrors the exit-side kinds so users
/// can pair them ("rises in on entry, drops out on resolve").
///
/// `intensity` (see `EffectIntensity`) multiplies spatial dimension.
/// `effectDurationScale` lengthens the entrance window; cascade
/// uses the duration as the PER-PILL window — total time is
/// `duration + perPillDelay * pillCount`.
public enum AppearEffect: String, Sendable, CaseIterable {
    /// No appear animation — pills paint at full size, no delay.
    case off
    /// 150ms scale-in 0.85 → 1.0 ease-out cubic — the historical
    /// perch default. Stays as the new default because it's the
    /// subtle option that doesn't shock the user on every activate.
    case pop
    /// Pills appear one after another with a small stagger,
    /// painting from top-left to bottom-right.
    case cascade
    /// Alpha 0 → 1 over the duration, no scale.
    case fadeIn = "fade-in"
    /// Pills appear from above, falling into their target rect.
    case dropIn = "drop-in"
    /// 0.4 → 1.0 scale + 0 → 1 alpha — like `explode` in reverse.
    case bloom
    /// Pick a random non-`none` non-`random` kind each activation.
    case random

    public static func parse(_ s: String) -> AppearEffect? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return AppearEffect(rawValue: t)
    }

    public func resolvingRandom() -> AppearEffect {
        guard self == .random else { return self }
        let pool = AppearEffect.allCases.filter {
            $0 != .random && $0 != .off
        }
        return pool.randomElement() ?? .pop
    }
}

/// Neon border preset for the pill perimeter — ports facet's
/// `[border]` vocabulary onto perch's pill geometry. Layered on
/// top of the theme palette; the theme picks pill body colors,
/// this picks the border's identity. Off by default — every pill
/// keeps the existing 1pt accent-tinted hairline.
public enum BorderEffect: String, Sendable, CaseIterable {
    case off
    case neon                   // electric cyan on blue base
    case cyber                  // teal / aqua matrix
    case vapor                  // synthwave pink → purple
    case kawaii                 // soft pastels
    case rainbow                // full-spectrum hue rotation
    case random                 // pick a non-off non-random kind at activation

    public static func parse(_ s: String) -> BorderEffect? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return BorderEffect(rawValue: t)
    }

    /// Resolve `.random` to a concrete effect, excluding `.off`
    /// (so random never collapses to no border) and itself.
    public func resolvingRandom() -> BorderEffect {
        guard self == .random else { return self }
        let pool = BorderEffect.allCases.filter { $0 != .random && $0 != .off }
        return pool.randomElement() ?? .neon
    }

    /// Base color the painter strokes the border with at hue
    /// offset 0. Returns nil for `.off` (caller falls back to the
    /// accent palette). Hues are picked to match facet's neon
    /// family — same intent: "this looks like a neon tube".
    public var baseHex: UInt32? {
        switch self.resolvingRandom() {
        case .off, .random:    return nil
        case .neon:            return 0x00E5FF
        case .cyber:           return 0x00FFCC
        case .vapor:           return 0xFF6EC7
        case .kawaii:          return 0xFFB6E1
        case .rainbow:         return 0xFFFFFF   // hue cycles, sat fixed
        }
    }
}

/// Overall magnitude scaler for `match` / `unmatch` effects — sill
/// Palette's shared knob (subtle 0.6× / normal 1.0× / bold 1.6× /
/// wild 2.5×, identical `parse`). The typealias keeps every PerchCore
/// signature compiling without an `import Palette` in each adapter
/// file; the `scale` shim preserves perch's CGFloat spelling of sill's
/// `multiplier` (Double). Multiplies the effect's spatial dimension
/// (explode scale, shake amplitude) but not its duration — the latency
/// budget is fixed.
public typealias EffectIntensity = Palette.EffectIntensity

public extension EffectIntensity {
    /// perch's CGFloat view of sill's `multiplier`.
    var scale: CGFloat { CGFloat(multiplier) }
}

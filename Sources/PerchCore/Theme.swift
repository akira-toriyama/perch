// Hint-pill palette presets. Ports facet's `[overlay] theme` knob
// vocabulary (see https://github.com/akira-toriyama/facet) into
// perch's single-surface UI: a `Theme` picks the **pill fill** /
// **accent (border + matched glow + typed-prefix)** / **text color**
// triple, plus the font family (monospaced vs rounded vs system).
//
// Stays in Core because the parsed config carries the enum across
// the seam; the Adapter (HintPainter) resolves it into NSColors at
// draw time. `paletteHex` therefore returns plain `0xRRGGBB` ints —
// no AppKit / CoreGraphics types here.
//
// All palettes are paired (primary, secondary) following facet's
// convention. perch only uses one accent today, so `accent` is the
// primary; `pillBg` is the background tint applied behind the label
// glyphs (drawn over the frosted blur). Most themes share white text
// (`textHex = 0xFFFFFF`) — the light themes (paper / cute / kawaii /
// mono-light) flip to dark text because the bg is light enough that
// white reads as washed-out.

import CoreGraphics
import Foundation

/// Color palette + typography preset for hint pills. Mirrors facet's
/// `[overlay] theme` vocabulary so users carrying a facet config over
/// see the same names.
///
/// Unknown / out-of-range values clamp to `.system` per the
/// typo-tolerance policy (see `PerchConfig`).
public enum Theme: String, Sendable, CaseIterable {

    // Adaptive — follows macOS light/dark; pills use NSColor.controlAccentColor.
    case system

    // Dark, monospace.
    case terminal
    case nord
    case dracula
    case gruvbox
    case catppuccin
    case rosepine
    case everforest
    case solarized
    case onedark
    case monokai
    case hacker

    // Neon — vivid electric on hue-tinted near-black.
    case neon
    case cyber
    case vapor

    // Light.
    case cute
    case kawaii
    case paper

    // Monochrome.
    case monoLight = "mono-light"
    case monoDark = "mono-dark"
    case monotone

    // Special — pick a random theme on each launch / --reload
    // (excludes `system` so a randomly-chosen palette never falls
    // back to the adaptive default mid-session).
    case random

    /// Parse a config value into a `Theme`. Whitespace tolerant,
    /// case-insensitive. Returns `nil` for unknown names so the
    /// caller can clamp to the default.
    public static func parse(_ s: String) -> Theme? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t.isEmpty { return nil }
        return Theme(rawValue: t)
    }

    /// Resolve `.random` to a concrete palette by picking from every
    /// other case (so the chosen theme stays stable for the rest of
    /// the session). Other cases pass through unchanged.
    public func resolvingRandom() -> Theme {
        guard self == .random else { return self }
        let pool = Theme.allCases.filter { $0 != .random && $0 != .system }
        return pool.randomElement() ?? .terminal
    }
}

/// Backend-neutral palette emitted by `Theme.palette(...)`. Color
/// channels are `0xRRGGBB` ints so PerchCore stays free of
/// AppKit / CoreGraphics types — the Adapter splits each into
/// NSColor components at draw time.
public struct ThemePalette: Sendable, Equatable {

    /// Pill background tint. Drawn over the frost blur (or a solid
    /// dark fill when `blur-enabled = false`), so it's typically a
    /// translucent accent — see `pillBgAlpha`.
    public let pillBgHex: UInt32

    /// Pill border + matched-glow + typed-prefix highlight. The
    /// "accent" the user perceives as the theme's identity color.
    public let accentHex: UInt32

    /// Hint label text color (the unrolled half of the label —
    /// everything after the already-typed prefix). White on dark
    /// themes, near-black on light themes.
    public let textHex: UInt32

    /// Color used for the "missed key" red flash. Most themes
    /// reuse `0xEF4444` (the wand miss-color), but some palettes
    /// override it to keep contrast against an unusual pill bg.
    public let missHex: UInt32

    /// Pill bg alpha when frost is on (.hudWindow blur layer
    /// underneath). Lower → more frost shows through; higher →
    /// more theme tint. `0.30` is the historical perch default.
    public let pillBgAlpha: CGFloat

    /// Font family used for hint labels. Monospaced is the
    /// historical default; rounded reads warmer on light/playful
    /// themes (cute / kawaii / rainbow); system is the macOS
    /// default sans, paired with the `paper` / `monotone` /
    /// `system` adaptive presets.
    public let font: ThemeFont

    public init(
        pillBgHex: UInt32,
        accentHex: UInt32,
        textHex: UInt32 = 0xFFFFFF,
        missHex: UInt32 = 0xEF4444,
        pillBgAlpha: CGFloat = 0.30,
        font: ThemeFont = .mono
    ) {
        self.pillBgHex = pillBgHex
        self.accentHex = accentHex
        self.textHex = textHex
        self.missHex = missHex
        self.pillBgAlpha = pillBgAlpha
        self.font = font
    }
}

/// Font family for hint labels. The adapter maps these to AppKit
/// fonts at draw time (`NSFont.monospacedSystemFont` /
/// `NSFont.systemFont` with `roundedFontDescriptor` etc.).
public enum ThemeFont: Sendable, Equatable {
    case mono
    case rounded
    case system
}

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

extension Theme {

    /// Catalog of built-in palettes keyed by theme case. `.system`
    /// and `.random` aren't in the dict — they have special handling
    /// in `palette()`. Centralising the table (vs the old switch)
    /// makes new themes a one-entry diff and enables a future
    /// `[overlay.theme.<name>]` user-defined palette to write into
    /// the same shape.
    public static let builtinPalettes: [Theme: ThemePalette] = [
        // Dark / mono.
        .terminal:   ThemePalette(pillBgHex: 0x0E1117, accentHex: 0x9ECE6A, textHex: 0xE6EDF3, font: .mono),
        .nord:       ThemePalette(pillBgHex: 0x2E3440, accentHex: 0x88C0D0, textHex: 0xECEFF4, font: .mono),
        .dracula:    ThemePalette(pillBgHex: 0x282A36, accentHex: 0xBD93F9, textHex: 0xF8F8F2, font: .mono),
        .gruvbox:    ThemePalette(pillBgHex: 0x282828, accentHex: 0xFE8019, textHex: 0xEBDBB2, font: .mono),
        .catppuccin: ThemePalette(pillBgHex: 0x1E1E2E, accentHex: 0xCBA6F7, textHex: 0xCDD6F4, font: .mono),
        .rosepine:   ThemePalette(pillBgHex: 0x191724, accentHex: 0xC4A7E7, textHex: 0xE0DEF4, font: .mono),
        .everforest: ThemePalette(pillBgHex: 0x2D353B, accentHex: 0xA7C080, textHex: 0xD3C6AA, font: .mono),
        .solarized:  ThemePalette(pillBgHex: 0x002B36, accentHex: 0x268BD2, textHex: 0x93A1A1, font: .mono),
        .onedark:    ThemePalette(pillBgHex: 0x282C34, accentHex: 0x61AFEF, textHex: 0xABB2BF, font: .mono),
        .monokai:    ThemePalette(pillBgHex: 0x272822, accentHex: 0xA6E22E, textHex: 0xF8F8F2, font: .mono),
        .hacker:     ThemePalette(pillBgHex: 0x000000, accentHex: 0x00FF41, textHex: 0xCFFFCF, font: .mono),

        // Neon — vivid electric on hue-tinted near-black; custom miss color.
        .neon:       ThemePalette(pillBgHex: 0x0A0E27, accentHex: 0x00E5FF, textHex: 0xE0F7FA, missHex: 0xFF00AA, font: .mono),
        .cyber:      ThemePalette(pillBgHex: 0x001A1F, accentHex: 0x00FFCC, textHex: 0xCCFFF7, missHex: 0xFF1493, font: .mono),
        .vapor:      ThemePalette(pillBgHex: 0x1A0E2E, accentHex: 0xFF6EC7, textHex: 0xF7D7FF, missHex: 0xFFD700, font: .mono),

        // Light — text flips dark because bg is light.
        .cute:       ThemePalette(pillBgHex: 0xFFE4F0, accentHex: 0xFF85B3, textHex: 0x4A1F38, missHex: 0xD63384, pillBgAlpha: 0.85, font: .rounded),
        .kawaii:     ThemePalette(pillBgHex: 0xF3E5F5, accentHex: 0x9B6BFF, textHex: 0x311B47, missHex: 0xFF5C8A, pillBgAlpha: 0.85, font: .rounded),
        .paper:      ThemePalette(pillBgHex: 0xFAFAFA, accentHex: 0x3366FF, textHex: 0x1A1A1A, missHex: 0xDC2626, pillBgAlpha: 0.90, font: .system),

        // Monochrome.
        .monoLight:  ThemePalette(pillBgHex: 0xFFFFFF, accentHex: 0x000000, textHex: 0x000000, missHex: 0xCC0000, pillBgAlpha: 0.92, font: .mono),
        .monoDark:   ThemePalette(pillBgHex: 0x000000, accentHex: 0xFFFFFF, textHex: 0xFFFFFF, missHex: 0xFF3344, pillBgAlpha: 0.92, font: .mono),
        .monotone:   ThemePalette(pillBgHex: 0x2A2A2A, accentHex: 0xB0B0B0, textHex: 0xE6E6E6, missHex: 0xE07070, pillBgAlpha: 0.55, font: .system),
    ]

    /// Sentinel palette for `.system` — `accentHex == 0` tells the
    /// Adapter to substitute `NSColor.controlAccentColor` so the
    /// daemon picks up the user's live macOS accent + light/dark.
    public static let systemPalette = ThemePalette(
        pillBgHex: 0x000000, accentHex: 0,
        textHex: 0xFFFFFF, missHex: 0xEF4444,
        pillBgAlpha: 0.30, font: .system)

    /// Resolve this theme into a backend-neutral palette. `.system`
    /// returns the sentinel `systemPalette`; `.random` resolves to a
    /// concrete case first; everything else is a dict lookup.
    public func palette() -> ThemePalette {
        let resolved = self.resolvingRandom()
        if resolved == .system { return Theme.systemPalette }
        return Theme.builtinPalettes[resolved] ?? Theme.systemPalette
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
    case none
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

    /// Resolve `.random` to a concrete kind. Excludes `.none` (so
    /// random never collapses to no animation) and `.random` itself.
    /// Other cases pass through unchanged.
    public func resolvingRandom() -> MatchEffect {
        guard self == .random else { return self }
        let pool = MatchEffect.allCases.filter { $0 != .random && $0 != .none }
        return pool.randomElement() ?? .fade
    }
}

/// What perch does when the user types a key that doesn't match
/// any visible label, or hits a non-letter key. The existing 200ms
/// **red flash** is the baseline — `unmatch` layers an additional
/// motion on top so the user FEELS the miss (motion is faster to
/// process than color).
public enum UnmatchEffect: String, Sendable, CaseIterable {
    case none
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
        let pool = UnmatchEffect.allCases.filter { $0 != .random && $0 != .none }
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
    case none
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
            $0 != .random && $0 != .none
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

/// Overall magnitude scaler for `match` / `unmatch` effects.
/// Ports wand's `intensity` vocabulary verbatim. Multiplies the
/// effect's spatial dimension (explode scale, shake amplitude) but
/// not its duration — the latency budget is fixed.
public enum EffectIntensity: String, Sendable, CaseIterable {
    case subtle  // 0.6× — calm
    case normal  // 1.0× — the calibrated baseline
    case bold    // 1.6× — more attention-grabbing
    case wild    // 2.5× — over-the-top

    public var scale: CGFloat {
        switch self {
        case .subtle: return 0.6
        case .normal: return 1.0
        case .bold:   return 1.6
        case .wild:   return 2.5
        }
    }

    public static func parse(_ s: String) -> EffectIntensity? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        return EffectIntensity(rawValue: t)
    }
}

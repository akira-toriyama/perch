import AppKit
import PaletteKit
import PerchCore
import XCTest

@testable import PerchAdapterMacOS

/// Guards the sill-PaletteKit colour convergence (ROADMAP #5). perch's
/// `HintPainter.resolvePalette` no longer hand-rolls the role colours — it
/// hands the chosen `ThemeSpec` to `PaletteKit.resolve` and reads the
/// materialised roles, layering ONLY its two overlays sill doesn't model
/// (the translucent pill surface + the per-app `[overlay].accent` override)
/// on top. These tests pin that wiring so a future field-swap (text ↦ muted,
/// accent ↦ secondary, …), a regressed sentinel, or a broken override fails
/// loudly in CI rather than silently recolouring the overlay. (Same spirit as
/// `BorderEffectMappingTests` for the border convergence.)
///
/// `swift test` needs full Xcode/XCTest, so this runs in CI — not on the
/// maintainer's CommandLineTools-only box.
@MainActor
final class PaletteResolveMappingTests: XCTestCase {

    /// sRGB components, so two NSColors built through different code paths
    /// (perch's `resolvePalette` vs a direct sill `resolve`) compare by value
    /// regardless of their originating colour space.
    private func rgba(_ c: NSColor) -> [CGFloat] {
        let s = c.usingColorSpace(.sRGB) ?? c
        return [s.redComponent, s.greenComponent, s.blueComponent, s.alphaComponent]
    }

    private func assertSameColor(
        _ a: NSColor, _ b: NSColor, _ msg: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let x = rgba(a), y = rgba(b)
        for i in 0 ..< 4 {
            XCTAssertEqual(x[i], y[i], accuracy: 0.001, msg, file: file, line: line)
        }
    }

    /// A concrete named theme: every role perch reads comes straight from
    /// sill's `resolve` of the same spec (the convergence is byte-identical),
    /// so this catches any field-swap in the mapping.
    func testNamedThemeRolesMatchSillResolve() {
        let cfg = PerchConfig.parse("[overlay]\ntheme = \"dracula\"")
        let palette = HintPainter.resolvePalette(cfg: cfg)
        let sill = resolve(perchThemeSpec("dracula"))
        assertSameColor(palette.accentColor, sill.primary, "accent ↦ resolved.primary")
        assertSameColor(palette.textColor, sill.foreground, "text ↦ resolved.foreground")
        assertSameColor(palette.missColor, sill.error, "miss ↦ resolved.error")
        XCTAssertEqual(palette.font, sill.font, "font ↦ resolved.font")
    }

    /// perch's `system` theme keeps the OS control-accent via sill's primary
    /// sentinel (0 ⇒ controlAccentColor), now resolved INSIDE PaletteKit —
    /// not perch's old hand-roll. The pill keeps its concrete white text.
    func testSystemThemeResolvesAccentToControlAccent() {
        let cfg = PerchConfig.parse("[overlay]\ntheme = \"system\"")
        let palette = HintPainter.resolvePalette(cfg: cfg)
        assertSameColor(palette.accentColor, .controlAccentColor,
                        "system theme accent ↦ controlAccentColor (sentinel)")
        assertSameColor(palette.textColor, NSColor(hex: 0xFFFFFF),
                        "system pill keeps white text")
    }

    /// `[overlay].accent = "#hex"` wins over the theme accent — perch's
    /// override, layered AFTER sill's resolve (which models none). The body
    /// roles still come from the theme.
    func testAccentOverrideWinsOverThemeAccent() {
        let cfg = PerchConfig.parse(
            "[overlay]\ntheme = \"dracula\"\naccent = \"#ff00ff\"")
        let palette = HintPainter.resolvePalette(cfg: cfg)
        assertSameColor(palette.accentColor, NSColor(hex: 0xFF00FF),
                        "explicit accent overrides the theme accent")
        assertSameColor(palette.textColor, resolve(perchThemeSpec("dracula")).foreground,
                        "override leaves the text on the theme")
    }

    /// `accent = "system"` (the default) means "no override" — the theme's
    /// own accent shows through unchanged.
    func testAccentSystemKeepsThemeAccent() {
        let cfg = PerchConfig.parse(
            "[overlay]\ntheme = \"dracula\"\naccent = \"system\"")
        let palette = HintPainter.resolvePalette(cfg: cfg)
        assertSameColor(palette.accentColor, resolve(perchThemeSpec("dracula")).primary,
                        "accent=system falls through to the theme accent")
    }
}

import XCTest
import Palette
@testable import PerchCore

/// Regression net for the sill theme migration (plan atelier). Before
/// this, perch had ZERO coverage of theme resolution — a hex / alpha /
/// font drift would have shipped silently. These tests pin:
///   * the sill bridge (`perchThemeSpec` / `perchCanonicalThemeName`),
///   * perch's two app-specific overlays (translucency + themed miss),
///   * the `system` dark-pill spec,
///   * config parsing (name validation, random stability, custom
///     palettes, reserved-name shadowing),
/// and — the headline of the migration — that perch now serves the
/// FACET-CANONICAL palette values from sill, not its old hand-rolled
/// catalog.
final class ThemeTests: XCTestCase {

    // MARK: - Name validation (perchCanonicalThemeName)

    func testCanonicalNamePassthroughAndCaseTrim() {
        XCTAssertEqual(perchCanonicalThemeName("nord"), "nord")
        XCTAssertEqual(perchCanonicalThemeName("  NORD  "), "nord")
        XCTAssertEqual(perchCanonicalThemeName("system"), "system")
        // mono-light / mono-dark keep their hyphenated rawValue.
        XCTAssertEqual(perchCanonicalThemeName("mono-light"), "mono-light")
    }

    func testCanonicalNameRejectsTypoAndEmpty() {
        // Unknown → nil so the caller clamps to "system" (perch's
        // loud-rejection / silent-clamp discipline). sill's paletteFor
        // would silently return terminal — that's exactly what this
        // guards against.
        XCTAssertNil(perchCanonicalThemeName("frob"))
        XCTAssertNil(perchCanonicalThemeName(""))
        XCTAssertNil(perchCanonicalThemeName("   "))
    }

    func testRandomResolvesToConcreteStableName() {
        // `random` resolves HERE to a concrete, non-meta name (so the
        // session theme is stable). Run a handful of draws.
        for _ in 0..<32 {
            guard let name = perchCanonicalThemeName("random") else {
                return XCTFail("random must resolve to a concrete name")
            }
            XCTAssertNotEqual(name, "random")
            XCTAssertNotEqual(name, "system")
            XCTAssertTrue(canonicalThemeNames.contains(name),
                          "\(name) not in canonicalThemeNames")
        }
    }

    func testGainsChompAndRainbowThemeNames() {
        // perch's old Theme enum lacked chomp and had rainbow only as a
        // border effect. Adopting sill's canonicalThemeNames adds both
        // as valid --theme= values.
        XCTAssertEqual(perchCanonicalThemeName("chomp"), "chomp")
        XCTAssertEqual(perchCanonicalThemeName("rainbow"), "rainbow")
    }

    // MARK: - sill-canonical adoption (the migration's headline)

    func testServesSillCanonicalValues() {
        // terminal: accent matched perch's old value already; text +
        // bg are sill-AUTHORITATIVE (perch's old text was 0xE6EDF3).
        let term = perchThemeSpec("terminal")
        XCTAssertEqual(term.accent.rgb, 0x9ECE6A)
        XCTAssertEqual(term.text.rgb, 0xC0CAF5)   // sill canonical, not old 0xE6EDF3
        XCTAssertEqual(term.bg?.rgb, 0x0E0F14)    // sill canonical, not old 0x0E1117

        // hacker: perch's old accent was 0x00FF41 — now sill's 0x33FF66.
        XCTAssertEqual(perchThemeSpec("hacker").accent.rgb, 0x33FF66)

        // A fully-matching theme is unchanged either way.
        XCTAssertEqual(perchThemeSpec("nord").accent.rgb, 0x88C0D0)
    }

    // MARK: - App-specific overlay: translucency (perchPillAlpha)

    func testPillAlphaTable() {
        XCTAssertEqual(perchPillAlpha("terminal"), 0.30)
        XCTAssertEqual(perchPillAlpha("monotone"), 0.55)
        XCTAssertEqual(perchPillAlpha("cute"), 0.85)
        XCTAssertEqual(perchPillAlpha("kawaii"), 0.85)
        XCTAssertEqual(perchPillAlpha("paper"), 0.90)
        XCTAssertEqual(perchPillAlpha("mono-light"), 0.92)
        XCTAssertEqual(perchPillAlpha("mono-dark"), 0.92)
        // chomp / rainbow (new) + unknown default to the dark 0.30.
        XCTAssertEqual(perchPillAlpha("chomp"), 0.30)
        XCTAssertEqual(perchPillAlpha("rainbow"), 0.30)
    }

    func testThemeSpecCarriesPerchAlpha() {
        // sill presets leave bgAlpha nil; perchThemeSpec must inject it
        // so the frosted pill stays translucent.
        XCTAssertEqual(perchThemeSpec("terminal").bgAlpha ?? -1, 0.30)
        XCTAssertEqual(perchThemeSpec("cute").bgAlpha ?? -1, 0.85)
        XCTAssertEqual(perchThemeSpec("monotone").bgAlpha ?? -1, 0.55)
    }

    // MARK: - App-specific overlay: themed miss (perchMissOverride)

    func testMissOverrideTable() {
        XCTAssertEqual(perchMissOverride("neon"), 0xFF00AA)
        XCTAssertEqual(perchMissOverride("cyber"), 0xFF1493)
        XCTAssertEqual(perchMissOverride("vapor"), 0xFFD700)
        XCTAssertEqual(perchMissOverride("monotone"), 0xE07070)
        XCTAssertNil(perchMissOverride("nord"))
        XCTAssertNil(perchMissOverride("terminal"))
    }

    func testThemeSpecBakesThemedMissIntoError() {
        // perch's themed miss lands on spec.error.
        XCTAssertEqual(perchThemeSpec("neon").error.rgb, 0xFF00AA)
        XCTAssertEqual(perchThemeSpec("vapor").error.rgb, 0xFFD700)
        // No override → sill's default error.
        XCTAssertEqual(perchThemeSpec("terminal").error.rgb, defaultErrorHex)
        XCTAssertEqual(perchThemeSpec("nord").error.rgb, defaultErrorHex)
        // chomp ships its OWN error in sill (arcade ghost-red) and perch
        // has no override, so it survives.
        XCTAssertEqual(perchThemeSpec("chomp").error.rgb, 0xFF0000)
    }

    // MARK: - system theme (perch's dark-pill spec, NOT sill's panel)

    func testSystemSpecIsPerchDarkPill() {
        let sys = perchThemeSpec("system")
        XCTAssertEqual(sys.bg?.rgb, perchSystemPillBgHex)   // concrete black, not nil
        XCTAssertEqual(sys.bg?.rgb, 0x000000)
        XCTAssertEqual(sys.text.rgb, 0xFFFFFF)              // white, not adaptive labelColor
        XCTAssertTrue(sys.usesSystemAccent)                 // borrows OS control-accent
        XCTAssertEqual(sys.bgAlpha ?? -1, 0.30)
        XCTAssertEqual(sys.font, .system)
    }

    // MARK: - Config: theme name parsing

    func testConfigThemeName() {
        XCTAssertEqual(
            PerchConfig.parse("[overlay]\ntheme = \"nord\"").overlay.theme,
            "nord")
        // Default (no key) is system.
        XCTAssertEqual(PerchConfig.parse("").overlay.theme, "system")
    }

    func testConfigThemeTypoClampsToSystemSilently() {
        // Config-file typo clamps to system per the TOML
        // clamp-don't-reject rule (the loud path is the --theme= CLI).
        XCTAssertEqual(
            PerchConfig.parse("[overlay]\ntheme = \"frob\"").overlay.theme,
            "system")
    }

    func testConfigRandomResolvesAtParse() {
        let name = PerchConfig.parse("[overlay]\ntheme = \"random\"").overlay.theme
        XCTAssertNotEqual(name, "random")
        XCTAssertNotEqual(name, "system")
        XCTAssertTrue(canonicalThemeNames.contains(name))
    }

    // MARK: - Config: custom palettes ([overlay.themes.<name>])

    func testCustomPaletteParsedAsThemeSpec() {
        let src = """
        [overlay.themes.mine]
        pill-bg = "#1a1a1a"
        accent = "#ff8800"
        text = "#ffffff"
        miss = "#00ff00"
        pill-bg-alpha = 0.7
        font = "rounded"

        [overlay]
        theme = "mine"
        """
        let cfg = PerchConfig.parse(src)
        // Selecting a custom palette keeps theme on "system" and routes
        // via customThemeName.
        XCTAssertEqual(cfg.overlay.theme, "system")
        XCTAssertEqual(cfg.overlay.customThemeName, "mine")
        guard let spec = cfg.overlay.customPalettes["mine"] else {
            return XCTFail("custom palette \"mine\" not parsed")
        }
        XCTAssertEqual(spec.bg?.rgb, 0x1A1A1A)
        XCTAssertEqual(spec.accent.rgb, 0xFF8800)
        XCTAssertEqual(spec.text.rgb, 0xFFFFFF)
        XCTAssertEqual(spec.error.rgb, 0x00FF00)     // miss → error
        XCTAssertEqual(spec.bgAlpha ?? -1, 0.7)
        XCTAssertEqual(spec.font, .rounded)
    }

    func testCustomPaletteCannotShadowBuiltin() {
        // A custom section named after a built-in (or a sill meta-name)
        // is skipped so it can never hide the canonical catalog.
        let src = """
        [overlay.themes.nord]
        accent = "#ff0000"

        [overlay.themes.chomp]
        accent = "#ff0000"
        """
        let cfg = PerchConfig.parse(src)
        XCTAssertNil(cfg.overlay.customPalettes["nord"])
        XCTAssertNil(cfg.overlay.customPalettes["chomp"])
    }

    func testCustomPaletteDefaultsForMissingKeys() {
        // Only accent set; the rest fall back to the parse defaults
        // (miss → default error, alpha → 0.55, font → mono).
        let src = """
        [overlay.themes.spartan]
        accent = "#abcdef"

        [overlay]
        theme = "spartan"
        """
        let cfg = PerchConfig.parse(src)
        guard let spec = cfg.overlay.customPalettes["spartan"] else {
            return XCTFail("custom palette not parsed")
        }
        XCTAssertEqual(spec.accent.rgb, 0xABCDEF)
        XCTAssertEqual(spec.error.rgb, 0xEF4444)   // miss default
        XCTAssertEqual(spec.bgAlpha ?? -1, 0.55)   // alpha default
        XCTAssertEqual(spec.font, .mono)           // font default
    }

    // MARK: - withTheme carries custom palettes

    func testWithThemeCarriesCustomPalettes() {
        let src = """
        [overlay.themes.mine]
        accent = "#ff8800"
        """
        let cfg = PerchConfig.parse(src)
        let switched = cfg.withTheme("nord", customName: nil)
        XCTAssertEqual(switched.overlay.theme, "nord")
        XCTAssertNil(switched.overlay.customThemeName)
        XCTAssertNotNil(switched.overlay.customPalettes["mine"],
                        "custom palettes must survive a theme switch")
    }
}

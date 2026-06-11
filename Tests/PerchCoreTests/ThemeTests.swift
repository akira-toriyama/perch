import XCTest
import Palette
@testable import PerchCore

/// Regression net for the sill theme bridge (plan atelier, Phase V
/// block-5: perch → sill 0.3.0). These pin:
///   * the sill bridge (`perchThemeSpec` / `perchCanonicalThemeName`),
///   * perch's one app-specific overlay — the frosted-pill translucency
///     (`perchPillAlpha`), now DERIVED from sill's `isLight` rather than
///     a theme-name list,
///   * the `system` dark-pill spec,
///   * config parsing (name validation, random stability, custom
///     palettes, reserved-name shadowing),
/// and — the headline of the 0.3.0 migration — that perch now serves the
/// Phase V 12-theme catalog with the new Tailwind role names
/// (background / foreground / muted / primary), not the old 0.1.0 names.
final class ThemeTests: XCTestCase {

    // MARK: - Name validation (perchCanonicalThemeName)

    func testCanonicalNamePassthroughAndCaseTrim() {
        XCTAssertEqual(perchCanonicalThemeName("dracula"), "dracula")
        XCTAssertEqual(perchCanonicalThemeName("  DRACULA  "), "dracula")
        XCTAssertEqual(perchCanonicalThemeName("system"), "system")
        // Hyphenated catalog names keep their rawValue.
        XCTAssertEqual(perchCanonicalThemeName("catppuccin-mocha"),
                       "catppuccin-mocha")
        XCTAssertEqual(perchCanonicalThemeName("shades-of-purple"),
                       "shades-of-purple")
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

    func testPhaseVCatalogCutsOldThemeNames() {
        // The Phase V 0-based reselect dropped these (folded into
        // terminal / rainbow, or cut outright). A user config naming one
        // now clamps to `system` rather than silently resolving — this
        // pins the cut so a regression that re-adds them is caught.
        for cut in ["nord", "cute", "kawaii", "paper", "monotone",
                    "mono-light", "mono-dark", "neon", "cyber", "vapor",
                    "onedark", "monokai", "solarized", "everforest",
                    "rosepine", "catppuccin", "hacker"] {
            XCTAssertNil(perchCanonicalThemeName(cut),
                         "\(cut) should be cut from the Phase V catalog")
        }
    }

    func testPhaseVCatalogAcceptsAllTwelveColorThemes() {
        // The blessed 12 color themes + system are all valid --theme= values.
        for name in ["terminal", "chomp", "rainbow", "cobalt2",
                     "shades-of-purple", "tokyo-hack", "github-dark",
                     "dracula", "catppuccin-mocha", "gruvbox",
                     "github-light", "catppuccin-latte", "system"] {
            XCTAssertEqual(perchCanonicalThemeName(name), name,
                           "\(name) must be a valid catalog name")
        }
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

    // MARK: - sill-canonical adoption (the migration's headline)

    func testServesSillCanonicalValues() {
        // terminal: Phase V redefined it to classic green-on-near-black
        // (the old hacker green folds in here; the old Tokyo-Night
        // terminal retired to tokyo-hack).
        let term = perchThemeSpec("terminal")
        XCTAssertEqual(term.primary.rgb, 0x33FF66)
        XCTAssertEqual(term.foreground.rgb, 0x9BFEDA)
        XCTAssertEqual(term.background?.rgb, 0x050805)

        // dracula: signature purple primary, unchanged from sill.
        XCTAssertEqual(perchThemeSpec("dracula").primary.rgb, 0xBD93F9)
        XCTAssertEqual(perchThemeSpec("dracula").background?.rgb, 0x282A36)

        // github-dark (a Phase V newcomer perch never had): link-blue.
        XCTAssertEqual(perchThemeSpec("github-dark").primary.rgb, 0x2F81F7)
    }

    // MARK: - App-specific overlay: translucency (perchPillAlpha)

    func testPillAlphaDerivedFromIsLight() {
        // perchPillAlpha is now a pure function of the spec's lightness
        // (background luminance > 0.5), NOT a theme-name table — so new
        // catalog light themes are handled with no perch-local list.
        XCTAssertEqual(perchPillAlpha(for: paletteFor("terminal")), 0.30)
        XCTAssertEqual(perchPillAlpha(for: paletteFor("dracula")), 0.30)
        XCTAssertEqual(perchPillAlpha(for: paletteFor("chomp")), 0.30)
        // The two surviving light themes ride higher so the pale fill is
        // not washed out under the frost.
        XCTAssertEqual(perchPillAlpha(for: paletteFor("github-light")), 0.85)
        XCTAssertEqual(perchPillAlpha(for: paletteFor("catppuccin-latte")), 0.85)
    }

    func testThemeSpecCarriesPerchAlpha() {
        // sill presets leave backgroundAlpha nil; perchThemeSpec must
        // inject it so the frosted pill stays translucent.
        XCTAssertEqual(perchThemeSpec("terminal").backgroundAlpha ?? -1, 0.30)
        XCTAssertEqual(perchThemeSpec("github-light").backgroundAlpha ?? -1, 0.85)
        XCTAssertEqual(perchThemeSpec("catppuccin-latte").backgroundAlpha ?? -1, 0.85)
    }

    // MARK: - Miss color flows through spec.error (no perch override)

    func testMissColorFlowsFromSpecError() {
        // perch no longer overrides the miss hue per theme (the 9 old
        // overrides all targeted now-cut themes). The miss flash reads
        // straight from sill's `error` role: a theme's own error, or the
        // shared default when it ships none.
        XCTAssertEqual(perchThemeSpec("terminal").error.rgb, 0xFF3B3B)  // terminal's own
        XCTAssertEqual(perchThemeSpec("chomp").error.rgb, 0xFF0000)     // arcade ghost-red
        XCTAssertEqual(perchThemeSpec("dracula").error.rgb, 0xFF5555)   // dracula's own
        // gruvbox ships no error → sill's shared default.
        XCTAssertEqual(perchThemeSpec("gruvbox").error.rgb, defaultErrorHex)
    }

    // MARK: - system theme (perch's dark-pill spec, NOT sill's panel)

    func testSystemSpecIsPerchDarkPill() {
        // Q6: perch's system is a local divergence — a concrete black
        // pill with fixed white ink that does NOT flip with the OS
        // appearance (sill's .system is an adaptive vibrancy panel with
        // background == nil). It borrows only the OS control-accent.
        let sys = perchThemeSpec("system")
        XCTAssertEqual(sys.background?.rgb, perchSystemPillBgHex)  // concrete black, not nil
        XCTAssertEqual(sys.background?.rgb, 0x000000)
        XCTAssertEqual(sys.foreground.rgb, 0xFFFFFF)              // white, not adaptive labelColor
        XCTAssertTrue(sys.usesSystemPrimary)                     // borrows OS control-accent
        XCTAssertEqual(sys.backgroundAlpha ?? -1, 0.30)
        XCTAssertEqual(sys.font, .system)
        // Concrete background auto-derives .fixed (atelier Q6).
        XCTAssertEqual(sys.backgroundMode, .fixed)
        XCTAssertFalse(sys.isLight)                              // black → dark pill
    }

    // MARK: - Config: theme name parsing

    func testConfigThemeName() {
        XCTAssertEqual(
            PerchConfig.parse("[overlay]\ntheme = \"dracula\"").overlay.theme,
            "dracula")
        // Default (no key) is system.
        XCTAssertEqual(PerchConfig.parse("").overlay.theme, "system")
    }

    func testConfigThemeTypoClampsToSystemSilently() {
        // Config-file typo clamps to system per the TOML
        // clamp-don't-reject rule (the loud path is the --theme= CLI).
        // A now-cut name (`nord`) is just a typo to the Phase V catalog.
        XCTAssertEqual(
            PerchConfig.parse("[overlay]\ntheme = \"frob\"").overlay.theme,
            "system")
        XCTAssertEqual(
            PerchConfig.parse("[overlay]\ntheme = \"nord\"").overlay.theme,
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
        XCTAssertEqual(spec.background?.rgb, 0x1A1A1A)
        XCTAssertEqual(spec.primary.rgb, 0xFF8800)
        XCTAssertEqual(spec.foreground.rgb, 0xFFFFFF)
        XCTAssertEqual(spec.error.rgb, 0x00FF00)     // miss → error
        XCTAssertEqual(spec.backgroundAlpha ?? -1, 0.7)
        XCTAssertEqual(spec.font, .rounded)
    }

    func testCustomPaletteMenuFont() {
        // FontKind gained .menu in sill 0.3.0; the custom-palette parser
        // accepts it (defaults to .mono on anything else).
        let src = """
        [overlay.themes.native]
        accent = "#abcdef"
        font = "menu"
        """
        let cfg = PerchConfig.parse(src)
        XCTAssertEqual(cfg.overlay.customPalettes["native"]?.font, .menu)
    }

    func testCustomPaletteCannotShadowBuiltin() {
        // A custom section named after a built-in (or a sill meta-name)
        // is skipped so it can never hide the canonical catalog.
        let src = """
        [overlay.themes.dracula]
        accent = "#ff0000"

        [overlay.themes.chomp]
        accent = "#ff0000"
        """
        let cfg = PerchConfig.parse(src)
        XCTAssertNil(cfg.overlay.customPalettes["dracula"])
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
        XCTAssertEqual(spec.primary.rgb, 0xABCDEF)
        XCTAssertEqual(spec.error.rgb, 0xEF4444)   // miss default
        XCTAssertEqual(spec.backgroundAlpha ?? -1, 0.55)   // alpha default
        XCTAssertEqual(spec.font, .mono)           // font default
    }

    // MARK: - withTheme carries custom palettes

    func testWithThemeCarriesCustomPalettes() {
        let src = """
        [overlay.themes.mine]
        accent = "#ff8800"
        """
        let cfg = PerchConfig.parse(src)
        let switched = cfg.withTheme("dracula", customName: nil)
        XCTAssertEqual(switched.overlay.theme, "dracula")
        XCTAssertNil(switched.overlay.customThemeName)
        XCTAssertNotNil(switched.overlay.customPalettes["mine"],
                        "custom palettes must survive a theme switch")
    }
}

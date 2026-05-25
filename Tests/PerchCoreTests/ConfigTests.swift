import XCTest
@testable import PerchCore

final class ConfigTests: XCTestCase {

    func testDefaultsWhenFileMissing() {
        let cfg = PerchConfig.parse("")
        XCTAssertEqual(cfg.hotkey, PerchConfig.defaultHotkey)
        XCTAssertEqual(cfg.cancelKey, PerchConfig.defaultCancelKey)
        XCTAssertEqual(cfg.alphabet, PerchConfig.defaultAlphabet)
        XCTAssertEqual(cfg.overlayAccent, "system")
        XCTAssertTrue(cfg.overlayBlurEnabled)
        XCTAssertTrue(cfg.overlayAnimEnabled)
        XCTAssertTrue(cfg.autoClickOnUnique)
    }

    func testCancelKeyParsing() {
        let src = """
        [hotkey]
        cancel = "q"
        """
        XCTAssertEqual(PerchConfig.parse(src).cancelKey, "q")
        // Empty / whitespace falls back to default.
        XCTAssertEqual(
            PerchConfig.parse("[hotkey]\ncancel = \"  \"").cancelKey,
            PerchConfig.defaultCancelKey)
    }

    func testHotkeyParsing() {
        XCTAssertEqual(
            HotkeyCombo.parse("shift+space"),
            HotkeyCombo(modifiers: .shift, key: "space"))
        XCTAssertEqual(
            HotkeyCombo.parse("Cmd+Alt+J"),
            HotkeyCombo(modifiers: [.cmd, .alt], key: "j"))
        XCTAssertNil(HotkeyCombo.parse(""))
        XCTAssertNil(HotkeyCombo.parse("frob+j"))
    }

    /// Out-of-range values clamp instead of erroring — same "typo
    /// can't break the daemon" policy stroke / facet enforce.
    func testValuesClampInsteadOfReject() {
        let src = """
        [overlay]
        font-size = 999
        accent = "not-a-color"
        """
        let cfg = PerchConfig.parse(src)
        XCTAssertEqual(cfg.overlayFontSize, 32)         // clamped to max
        XCTAssertEqual(cfg.overlayAccent, "system")     // bad → default
    }

    func testAccentParsing() {
        XCTAssertEqual(
            PerchConfig.parse("[overlay]\naccent = \"#3b82f6\"")
                .overlayAccent, "#3b82f6")
        // Case-insensitive + system alias.
        XCTAssertEqual(
            PerchConfig.parse("[overlay]\naccent = \"System\"")
                .overlayAccent, "system")
        XCTAssertEqual(
            PerchConfig.parse("[overlay]\naccent = \"accent\"")
                .overlayAccent, "system")
    }

    /// Alphabet duplicates and non-letters are silently dropped.
    func testAlphabetSanitisation() {
        let src = """
        [labels]
        alphabet = "aaa BCB-12"
        """
        let cfg = PerchConfig.parse(src)
        XCTAssertEqual(cfg.alphabet, "abc")
    }

    func testRoleArrayParses() {
        let src = """
        [behavior]
        roles = ["Button", "Link"]
        exclude-apps = ["com.evil.app"]
        """
        let cfg = PerchConfig.parse(src)
        XCTAssertEqual(cfg.roles, ["Button", "Link"])
        XCTAssertEqual(cfg.excludeApps, ["com.evil.app"])
    }

    /// Hotkey strings that `HotkeyCombo.parse` rejects (unknown
    /// modifier, empty string) must fall through to the default —
    /// never crash the daemon at config-load time.
    ///
    /// Note: `parse` is intentionally permissive about the *key*
    /// component — it accepts any non-empty trailing token without
    /// looking it up in `HotkeyMonitor.keyCode(for:)`. So strings
    /// like `"foo"` or `"+space"` (split drops the empty leading
    /// part) round-trip as a valid combo at the parser level and
    /// only get rejected at install time. This test pins the
    /// *parser*-level rejections, which is what `PerchConfig`
    /// relies on for its fallback.
    func testInvalidHotkeyFallsBackToDefault() {
        let bads = [
            "",                // no last part → nil
            "frob+space",      // unknown modifier → nil
            "shift+frob+j",    // mid-position unknown modifier → nil
        ]
        for s in bads {
            let cfg = PerchConfig.parse("[hotkey]\nactive = \"\(s)\"")
            XCTAssertEqual(
                cfg.hotkey, PerchConfig.defaultHotkey,
                "expected default for invalid hotkey \"\(s)\"")
        }
    }

    /// Negative / zero / huge font sizes clamp to the allowed
    /// range (8..32) rather than rendering as text-the-size-of-a-
    /// pixel-or-the-screen.
    func testFontSizeClampsBothEnds() {
        let lo = PerchConfig.parse("[overlay]\nfont-size = -10")
        XCTAssertEqual(lo.overlayFontSize, 8)
        let hi = PerchConfig.parse("[overlay]\nfont-size = 9999")
        XCTAssertEqual(hi.overlayFontSize, 32)
        let zero = PerchConfig.parse("[overlay]\nfont-size = 0")
        XCTAssertEqual(zero.overlayFontSize, 8)
    }

    /// Empty / whitespace-only alphabet falls back to the default.
    /// An unconfigured alphabet must never produce zero labels —
    /// that would silently disable hint mode.
    func testEmptyAlphabetFallsBackToDefault() {
        let cfg = PerchConfig.parse("[labels]\nalphabet = \"\"")
        XCTAssertEqual(cfg.alphabet, PerchConfig.defaultAlphabet)
        let ws = PerchConfig.parse("[labels]\nalphabet = \"   \"")
        XCTAssertEqual(ws.alphabet, PerchConfig.defaultAlphabet)
    }

    /// `prioritise-center` is a boolean knob; non-bool input
    /// should default to true (the more useful behaviour) rather
    /// than silently flip to false.
    func testPrioritiseCenterDefaultsTrue() {
        let cfg = PerchConfig.parse("")
        XCTAssertTrue(cfg.prioritiseCenter)
    }

    /// Section re-open is part of the TOML 1.0 grammar (`[a]` …
    /// `[b]` … `[a]` is a single `[a]` section). Our subset
    /// parser should honour it so a user's config that re-opens
    /// `[hotkey]` (e.g. to override one key per environment) works.
    func testReopenedSectionMergesKeys() {
        let src = """
        [hotkey]
        active = "ctrl+space"
        [overlay]
        accent = "#ff0000"
        [hotkey]
        cancel = "q"
        """
        let cfg = PerchConfig.parse(src)
        XCTAssertEqual(cfg.hotkey,
                       HotkeyCombo(modifiers: .ctrl, key: "space"))
        XCTAssertEqual(cfg.cancelKey, "q")
        XCTAssertEqual(cfg.overlayAccent, "#ff0000")
    }

    /// Hotkey combos can include multiple modifiers, in any order,
    /// case-insensitively. The parser must canonicalise the key
    /// to lowercase and accept the modifiers as a set.
    func testHotkeyComboModifierVariations() {
        XCTAssertEqual(
            HotkeyCombo.parse("CMD+SHIFT+J"),
            HotkeyCombo(modifiers: [.cmd, .shift], key: "j"))
        XCTAssertEqual(
            HotkeyCombo.parse("alt+ctrl+f1"),
            HotkeyCombo(modifiers: [.alt, .ctrl], key: "f1"))
        // Modifier aliases.
        XCTAssertEqual(
            HotkeyCombo.parse("option+command+a"),
            HotkeyCombo(modifiers: [.alt, .cmd], key: "a"))
        // Bare key with no modifiers is parseable.
        XCTAssertEqual(
            HotkeyCombo.parse("space"),
            HotkeyCombo(modifiers: [], key: "space"))
    }
}

import XCTest
@testable import PerchCore

final class ConfigTests: XCTestCase {

    func testDefaultsWhenFileMissing() {
        let cfg = PerchConfig.parse("")
        XCTAssertEqual(cfg.hotkey.active, PerchConfig.defaultHotkey)
        XCTAssertEqual(cfg.hotkey.cancel, PerchConfig.defaultCancelKey)
        XCTAssertEqual(cfg.labels.alphabet, PerchConfig.defaultAlphabet)
        XCTAssertEqual(cfg.overlay.accent, "system")
        XCTAssertTrue(cfg.overlay.blurEnabled)
        XCTAssertTrue(cfg.overlay.animEnabled)
        XCTAssertTrue(cfg.behavior.autoClickOnUnique)
    }

    func testCancelKeyParsing() {
        let src = """
        [hotkey]
        cancel = "q"
        """
        XCTAssertEqual(PerchConfig.parse(src).hotkey.cancel, "q")
        // Empty / whitespace falls back to default.
        XCTAssertEqual(
            PerchConfig.parse("[hotkey]\ncancel = \"  \"").hotkey.cancel,
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
        XCTAssertEqual(cfg.overlay.fontSize, 32)         // clamped to max
        XCTAssertEqual(cfg.overlay.accent, "system")     // bad → default
    }

    func testAccentParsing() {
        XCTAssertEqual(
            PerchConfig.parse("[overlay]\naccent = \"#3b82f6\"")
                .overlay.accent, "#3b82f6")
        // Case-insensitive + system alias.
        XCTAssertEqual(
            PerchConfig.parse("[overlay]\naccent = \"System\"")
                .overlay.accent, "system")
        XCTAssertEqual(
            PerchConfig.parse("[overlay]\naccent = \"accent\"")
                .overlay.accent, "system")
    }

    /// Alphabet duplicates and non-letters are silently dropped.
    func testAlphabetSanitisation() {
        let src = """
        [labels]
        alphabet = "aaa BCB-12"
        """
        let cfg = PerchConfig.parse(src)
        XCTAssertEqual(cfg.labels.alphabet, "abc")
    }

    func testRoleArrayParses() {
        let src = """
        [behavior]
        roles = ["Button", "Link"]
        exclude-apps = ["com.evil.app"]
        """
        let cfg = PerchConfig.parse(src)
        XCTAssertEqual(cfg.behavior.roles, ["Button", "Link"])
        XCTAssertEqual(cfg.behavior.excludeApps, ["com.evil.app"])
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
                cfg.hotkey.active, PerchConfig.defaultHotkey,
                "expected default for invalid hotkey \"\(s)\"")
        }
    }

    /// Negative / zero / huge font sizes clamp to the allowed
    /// range (8..32) rather than rendering as text-the-size-of-a-
    /// pixel-or-the-screen.
    func testFontSizeClampsBothEnds() {
        let lo = PerchConfig.parse("[overlay]\nfont-size = -10")
        XCTAssertEqual(lo.overlay.fontSize, 8)
        let hi = PerchConfig.parse("[overlay]\nfont-size = 9999")
        XCTAssertEqual(hi.overlay.fontSize, 32)
        let zero = PerchConfig.parse("[overlay]\nfont-size = 0")
        XCTAssertEqual(zero.overlay.fontSize, 8)
    }

    /// Empty / whitespace-only alphabet falls back to the default.
    /// An unconfigured alphabet must never produce zero labels —
    /// that would silently disable hint mode.
    func testEmptyAlphabetFallsBackToDefault() {
        let cfg = PerchConfig.parse("[labels]\nalphabet = \"\"")
        XCTAssertEqual(cfg.labels.alphabet, PerchConfig.defaultAlphabet)
        let ws = PerchConfig.parse("[labels]\nalphabet = \"   \"")
        XCTAssertEqual(ws.labels.alphabet, PerchConfig.defaultAlphabet)
    }

    /// `prioritise-center` is a boolean knob; non-bool input
    /// should default to true (the more useful behaviour) rather
    /// than silently flip to false.
    func testPrioritiseCenterDefaultsTrue() {
        let cfg = PerchConfig.parse("")
        XCTAssertTrue(cfg.labels.prioritiseCenter)
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
        XCTAssertEqual(cfg.hotkey.active,
                       HotkeyCombo(modifiers: .ctrl, key: "space"))
        XCTAssertEqual(cfg.hotkey.cancel, "q")
        XCTAssertEqual(cfg.overlay.accent, "#ff0000")
    }

    // MARK: - Per-app overrides (#37)

    /// A `[behavior."<bundle-id>"]` section parses into a
    /// `BehaviorOverrides` keyed by the bundle id, with only the
    /// keys the user explicitly set carrying values. The global
    /// `[behavior]` section is unaffected — overrides decorate, not
    /// replace.
    func testPerAppOverridesParse() {
        let src = """
        [behavior]
        roles = ["Button", "Link"]
        min-size = 6
        auto-click-on-unique = true

        [behavior."com.google.Chrome"]
        min-size = 20

        [behavior."com.microsoft.Word"]
        roles = ["Button", "MenuItem"]
        auto-click-on-unique = false
        """
        let cfg = PerchConfig.parse(src)
        XCTAssertEqual(cfg.behavior.roles, ["Button", "Link"])
        XCTAssertEqual(cfg.behavior.minSize, 6)
        XCTAssertTrue(cfg.behavior.autoClickOnUnique)

        XCTAssertEqual(cfg.behavior.perApp.count, 2)
        let chrome = cfg.behavior.perApp["com.google.Chrome"]
        XCTAssertNotNil(chrome)
        XCTAssertNil(chrome?.roles)
        XCTAssertEqual(chrome?.minSize, 20)
        XCTAssertNil(chrome?.autoClickOnUnique)

        let word = cfg.behavior.perApp["com.microsoft.Word"]
        XCTAssertEqual(word?.roles, ["Button", "MenuItem"])
        XCTAssertNil(word?.minSize)
        XCTAssertEqual(word?.autoClickOnUnique, false)
    }

    /// `effectiveX(for:)` resolvers return the per-app value when
    /// the section sets the key, and fall through to the global
    /// value when the section omits it (or when the bundle id has
    /// no override at all). This is the contract `AXUIElementSource`
    /// and `OverlayWindow` rely on at hint-mode entry.
    func testEffectiveResolversFallThroughToGlobal() {
        let src = """
        [behavior]
        roles = ["Button", "Link"]
        min-size = 6
        auto-click-on-unique = true

        [behavior."com.google.Chrome"]
        min-size = 20

        [behavior."com.microsoft.Word"]
        auto-click-on-unique = false
        """
        let cfg = PerchConfig.parse(src)

        // Chrome: min-size overridden, roles + auto-click inherited.
        XCTAssertEqual(cfg.behavior.effectiveMinSize(for: "com.google.Chrome"), 20)
        XCTAssertEqual(cfg.behavior.effectiveRoles(for: "com.google.Chrome"),
                       ["Button", "Link"])
        XCTAssertTrue(
            cfg.behavior.effectiveAutoClickOnUnique(for: "com.google.Chrome"))

        // Word: auto-click overridden, others inherited.
        XCTAssertFalse(
            cfg.behavior.effectiveAutoClickOnUnique(for: "com.microsoft.Word"))
        XCTAssertEqual(cfg.behavior.effectiveMinSize(for: "com.microsoft.Word"), 6)

        // Unknown bundle id → globals across the board.
        XCTAssertEqual(cfg.behavior.effectiveMinSize(for: "com.unknown.App"), 6)
        XCTAssertEqual(cfg.behavior.effectiveRoles(for: "com.unknown.App"),
                       ["Button", "Link"])
        XCTAssertTrue(cfg.behavior.effectiveAutoClickOnUnique(for: "com.unknown.App"))

        // nil bundle id (no frontmost app) → globals.
        XCTAssertEqual(cfg.behavior.effectiveMinSize(for: nil), 6)
    }

    /// Negative `min-size` in an override clamps to 0 (same policy
    /// as the global key). Unknown keys inside the section are
    /// silently ignored — a typo in a per-app key cannot break the
    /// daemon.
    func testPerAppOverridesClampAndIgnoreUnknown() {
        let src = """
        [behavior."com.foo.Bar"]
        min-size = -50
        not-a-real-key = true
        """
        let cfg = PerchConfig.parse(src)
        let o = cfg.behavior.perApp["com.foo.Bar"]
        XCTAssertEqual(o?.minSize, 0)
    }

    /// A section header with no recognised keys is dropped — adding
    /// `[behavior."com.foo"]` alone shouldn't inflate the
    /// per-app-override count surfaced by `perch --validate`.
    func testEmptyPerAppSectionIsDropped() {
        let src = """
        [behavior."com.foo.Bar"]
        """
        let cfg = PerchConfig.parse(src)
        XCTAssertTrue(cfg.behavior.perApp.isEmpty)
    }

    // MARK: - [regional] frame floor (#34 follow-up)

    /// `[regional].min-width` / `min-height` populate the regional
    /// frame floor that `AXUIElementSource.enumerateRegions()` reads
    /// at walk time. Defaults to 200×100; explicit values override.
    func testRegionalMinSizeKnobsParse() {
        let cfg = PerchConfig.parse("")
        XCTAssertEqual(cfg.regional.minWidth, 200)
        XCTAssertEqual(cfg.regional.minHeight, 100)

        let custom = PerchConfig.parse("""
        [regional]
        min-width = 320
        min-height = 180
        """)
        XCTAssertEqual(custom.regional.minWidth, 320)
        XCTAssertEqual(custom.regional.minHeight, 180)
    }

    /// Negative values clamp to 0 (typo-tolerance); the unset axis
    /// stays at its default — keys are independent.
    func testRegionalMinSizeClampsAndIndependent() {
        let cfg = PerchConfig.parse("""
        [regional]
        min-width = -50
        """)
        XCTAssertEqual(cfg.regional.minWidth, 0)
        XCTAssertEqual(cfg.regional.minHeight, 100)
    }

    // MARK: - [search.synonyms] (#53)

    /// `[search.synonyms]` populates `searchSynonyms`. Keys are
    /// lowercased; the entries flow through to
    /// `SearchFilter.rank(...)` so the user-typed form (`rm`) can
    /// surface a "Delete" match.
    func testSearchSynonymsParse() {
        let src = """
        [search.synonyms]
        close = ["shut", "quit", "kill"]
        delete = ["remove", "trash", "rm"]
        """
        let cfg = PerchConfig.parse(src)
        XCTAssertEqual(cfg.search.synonyms["close"],
                       ["shut", "quit", "kill"])
        XCTAssertEqual(cfg.search.synonyms["delete"],
                       ["remove", "trash", "rm"])
    }

    /// Empty arrays / empty keys / non-array values are dropped per
    /// typo-tolerance — a malformed line never breaks the lookup.
    func testSearchSynonymsTypoTolerant() {
        let src = """
        [search.synonyms]
        ok = ["alright"]
        empty = []
        wrong = "string-not-array"
        """
        let cfg = PerchConfig.parse(src)
        XCTAssertEqual(cfg.search.synonyms.keys.sorted(), ["ok"])
        XCTAssertEqual(cfg.search.synonyms["ok"], ["alright"])
    }

    /// No `[search.synonyms]` section → empty dictionary so the
    /// ranker stays in pure-fuzzy mode (no behaviour change for
    /// users who haven't opted in).
    func testSearchSynonymsDefaultsEmpty() {
        XCTAssertTrue(PerchConfig.parse("").search.synonyms.isEmpty)
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

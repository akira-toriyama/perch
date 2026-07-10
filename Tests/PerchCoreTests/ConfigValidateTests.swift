import XCTest
@testable import PerchCore

/// `PerchConfig.validate` — structural validation against the SAME
/// `configSpec` that drives decode + `--emit-schema` (sill 1.29.0's
/// `Spec.validate` bridge, t-0029). The strict counterpart to the lenient
/// `parse()`/`load()`: it surfaces the type / enum / range / unknown-key
/// mismatches the loader silently clamps or ignores.
final class ConfigValidateTests: XCTestCase {

    // MARK: - no regression: the shipped template validates clean

    /// The committed `config.toml` template MUST validate with zero errors —
    /// the keys it uses are exactly the keys the spec declares. (This is the
    /// guard that catches the spec drifting from the template, e.g. a key
    /// renamed in one but not the other.)
    func testCommittedTemplateValidatesClean() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/PerchCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        let url = repoRoot.appendingPathComponent("config.toml")
        let source = try String(contentsOf: url, encoding: .utf8)
        let errors = try PerchConfig.validate(source)
        XCTAssertEqual(errors, [],
                       "shipped config.toml should validate clean; got: "
                           + errors.map(\.message).joined(separator: "; "))
    }

    /// An empty document (missing-file case → defaults) is valid: sections are
    /// optional, only present values are walked.
    func testEmptyDocumentIsValid() throws {
        XCTAssertEqual(try PerchConfig.validate(""), [])
    }

    // MARK: - it catches what load() silently accepts

    func testUnknownKeyIsReported() throws {
        // `load()` would silently ignore this; validate surfaces it.
        let errors = try PerchConfig.validate("""
        [overlay]
        shortcut-badge = true
        bogus-key = 1
        """)
        XCTAssertTrue(errors.contains {
            if case .unknownKey(let k) = $0.rule { return k == "bogus-key" }
            return false
        }, "unknown key should be reported; got \(errors.map(\.rule))")
    }

    func testWrongTypeIsReported() throws {
        // `shortcut-badge` is a boolean; a string is a type mismatch.
        let errors = try PerchConfig.validate("""
        [overlay]
        shortcut-badge = "yes"
        """)
        XCTAssertTrue(errors.contains {
            if case .typeMismatch(let k, _) = $0.rule { return k == "shortcut-badge" }
            return false
        }, "type mismatch should be reported; got \(errors.map(\.rule))")
    }

    /// A genuine TOML syntax error throws (distinct from a schema violation) —
    /// the caller maps it to exit 2.
    func testUnparseableSourceThrows() {
        XCTAssertThrowsError(try PerchConfig.validate("[overlay\nbad"))
    }

    // MARK: - typed dynamicTable inner keys (t-wnvm)
    //
    // The three open maps used to be bare-permissive: a typo'd INNER key
    // passed schema + validate and the loader silently fell back to the
    // default. Their `DynamicValue` shapes close that hole. The loader
    // stays lenient (clamp / per-key default); only the validator got loud.

    func testCustomThemeCleanEntryValidates() throws {
        let errors = try PerchConfig.validate("""
        [overlay.themes.my-theme]
        pill-bg       = "#1a1a1a"
        accent        = "#ff8800"
        text          = "#ffffff"
        miss          = "#dc2626"
        pill-bg-alpha = 0.55
        font          = "rounded"
        """)
        XCTAssertEqual(errors, [],
                       "a well-formed custom palette validates clean; got: "
                           + errors.map(\.message).joined(separator: "; "))
    }

    func testCustomThemeTypoInnerKeyIsReported() throws {
        // THE motivating case: `pillbg` (vs `pill-bg`) used to slip through
        // and the palette silently rendered with the default black body.
        let errors = try PerchConfig.validate("""
        [overlay.themes.my-theme]
        pillbg = "#1a1a1a"
        """)
        XCTAssertTrue(errors.contains {
            if case .unknownKey(let k) = $0.rule { return k == "pillbg" }
            return false
        }, "a typo'd palette key should be reported; got \(errors.map(\.message))")
    }

    func testCustomThemeWrongTypeAndBadFontAreReported() throws {
        let errors = try PerchConfig.validate("""
        [overlay.themes.my-theme]
        pill-bg-alpha = "high"
        font          = "comic"
        """)
        XCTAssertTrue(errors.contains {
            if case .typeMismatch(let k, _) = $0.rule { return k == "pill-bg-alpha" }
            return false
        }, "a non-number alpha should be reported; got \(errors.map(\.message))")
        XCTAssertTrue(errors.contains {
            if case .notInEnum(let k, _, _) = $0.rule { return k == "font" }
            return false
        }, "an unknown font should be reported; got \(errors.map(\.message))")
    }

    func testPerAppOverrideCleanEntryValidates() throws {
        let errors = try PerchConfig.validate("""
        [behavior."com.google.Chrome"]
        roles = ["AXButton", "AXLink"]
        min-size = 20
        auto-click-on-unique = false
        appear-effect = "pop"
        """)
        XCTAssertEqual(errors, [],
                       "a well-formed per-app override validates clean; got: "
                           + errors.map(\.message).joined(separator: "; "))
    }

    func testPerAppOverrideTypoInnerKeyIsReported() throws {
        let errors = try PerchConfig.validate("""
        [behavior."com.microsoft.Word"]
        min-siez = 20
        """)
        XCTAssertTrue(errors.contains {
            if case .unknownKey(let k) = $0.rule { return k == "min-siez" }
            return false
        }, "a typo'd per-app key should be reported; got \(errors.map(\.message))")
    }

    func testPerAppOverrideBadEffectEnumIsReported() throws {
        // `explode` is a MATCH effect; appear-effect's domain doesn't have it.
        // The loader treats it as absent (inherits the global); validate names it.
        let errors = try PerchConfig.validate("""
        [behavior."com.figma.Desktop"]
        appear-effect = "explode"
        """)
        XCTAssertTrue(errors.contains {
            if case .notInEnum(let k, _, _) = $0.rule { return k == "appear-effect" }
            return false
        }, "an out-of-domain effect should be reported; got \(errors.map(\.message))")
    }

    func testBehaviorStaticKeyTypoStillFlagged() throws {
        // With the typed open map on [behavior], a typo'd STATIC key is seen
        // as a dynamic per-app key whose value isn't a table — flagged as a
        // type mismatch (a worse message than unknown-key, accepted trade for
        // never false-rejecting an unusual bundle-id key).
        let errors = try PerchConfig.validate("""
        [behavior]
        min-siez = 20
        """)
        XCTAssertTrue(errors.contains {
            if case .typeMismatch(let k, _) = $0.rule { return k == "min-siez" }
            return false
        }, "a typo'd [behavior] static key must still be flagged; got \(errors.map(\.message))")
    }

    func testSynonymsCleanEntryValidates() throws {
        let errors = try PerchConfig.validate("""
        [search.synonyms]
        close = ["shut", "quit", "kill"]
        open  = ["launch", "start"]
        """)
        XCTAssertEqual(errors, [],
                       "well-formed synonym arrays validate clean; got: "
                           + errors.map(\.message).joined(separator: "; "))
    }

    func testSynonymsScalarValueIsReported() throws {
        // `close = "shut"` used to be silently ignored by the loader
        // (asStringArray returns nil on a scalar) with no signal anywhere.
        let errors = try PerchConfig.validate("""
        [search.synonyms]
        close = "shut"
        """)
        XCTAssertTrue(errors.contains {
            if case .typeMismatch(let k, _) = $0.rule { return k == "close" }
            return false
        }, "a scalar synonym value should be reported; got \(errors.map(\.message))")
    }

    func testSynonymsNonStringElementIsReported() throws {
        let errors = try PerchConfig.validate("""
        [search.synonyms]
        close = ["shut", 3]
        """)
        XCTAssertTrue(errors.contains {
            if case .typeMismatch(let k, _) = $0.rule { return k == "close" }
            return false
        }, "a non-string synonym element should be reported; got \(errors.map(\.message))")
    }
}

/// `PerchConfig.loadWarnings` — the validate-then-warn seam the DAEMON load
/// path (runServer + reload) uses. Same schema check as `--validate`, but
/// surfaced as warnings without rejecting: proves violations warn on the LOAD
/// path, not only via the `config --validate` CLI verb.
final class ConfigLoadWarnTests: XCTestCase {

    func testLoadPathWarnsOnSchemaViolation() {
        let warnings = PerchConfig.loadWarnings("""
        [overlay]
        shortcut-badge = "yes"
        """)
        XCTAssertFalse(warnings.isEmpty,
                       "load path must warn on a schema violation")
        XCTAssertTrue(warnings.contains { $0.contains("shortcut-badge") },
                      "warning should name the offending key; got \(warnings)")
    }

    func testCleanConfigProducesNoWarnings() {
        XCTAssertEqual(PerchConfig.loadWarnings(""), [])
    }

    func testUnparseableSourceProducesNoWarnings() {
        // Matches today's silent lenient load — A1 only surfaces SCHEMA
        // violations on a parseable doc, never a syntax-error warning.
        XCTAssertEqual(PerchConfig.loadWarnings("[overlay\nbad"), [])
    }

    func testLoadPathWarningNamesTypoedInnerKey() {
        // t-wnvm end-to-end: a typo'd dynamicTable INNER key surfaces at
        // daemon load/reload (via A1's loadWarnings), naming the key.
        let warnings = PerchConfig.loadWarnings("""
        [overlay.themes.my-theme]
        pillbg = "#1a1a1a"
        """)
        XCTAssertTrue(warnings.contains { $0.contains("pillbg") },
                      "load warning should name the typo'd inner key; got \(warnings)")
    }
}

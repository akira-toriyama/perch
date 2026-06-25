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
}

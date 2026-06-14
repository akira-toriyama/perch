import XCTest
@testable import PerchCore

/// The committed `config.schema.json` (shipped next to `config.toml`,
/// pointed at by its `#:schema` directive) MUST equal what the live spec
/// emits — otherwise editor completion/validation drifts from the actual
/// parser. The schema and the decode are both generated from the one
/// `PerchConfig.configSpec`, so this guards the committed copy against a
/// stale regeneration.
///
/// Regenerate with: `perch --emit-schema > config.schema.json`.
final class ConfigSchemaDriftTests: XCTestCase {

    func testCommittedSchemaMatchesSpec() throws {
        // Locate the repo-root schema relative to THIS source file, so the
        // check is independent of the test runner's working directory.
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/PerchCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // <repo root>
        let url = repoRoot.appendingPathComponent("config.schema.json")
        let committed = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(
            committed, PerchConfig.jsonSchema,
            "config.schema.json is stale — run "
                + "`perch --emit-schema > config.schema.json` and commit.")
    }
}

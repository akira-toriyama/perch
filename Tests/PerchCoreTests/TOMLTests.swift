import XCTest
@testable import PerchCore

final class TOMLTests: XCTestCase {

    func testBasicParse() {
        let src = """
        # leading comment
        [section]
        name = "perch"
        count = 42
        ratio = 0.5
        on = true
        list = ["a", "b", "c"]
        """
        let doc = TOML.parse(src)
        XCTAssertEqual(doc["section"]?["name"]?.asString, "perch")
        XCTAssertEqual(doc["section"]?["count"]?.asInt, 42)
        XCTAssertEqual(doc["section"]?["ratio"]?.asDouble, 0.5)
        XCTAssertEqual(doc["section"]?["on"]?.asBool, true)
        XCTAssertEqual(doc["section"]?["list"]?.asStringArray, ["a", "b", "c"])
    }

    func testInlineCommentInsideStringPreserved() {
        let src = """
        [s]
        x = "value # not a comment"   # actual comment
        """
        let doc = TOML.parse(src)
        XCTAssertEqual(doc["s"]?["x"]?.asString, "value # not a comment")
    }

    func testMalformedLineIsDropped() {
        let src = """
        [s]
        good = "ok"
        bad-line-without-equals
        """
        let doc = TOML.parse(src)
        XCTAssertEqual(doc["s"]?["good"]?.asString, "ok")
        XCTAssertNil(doc["s"]?["bad-line-without-equals"])
    }

    func testHexIntegerForColorKey() {
        let src = """
        [c]
        color = 0xff0000
        """
        let doc = TOML.parse(src)
        XCTAssertEqual(doc["c"]?["color"]?.asInt, 0xff0000)
    }

    /// Escape sequences inside double-quoted strings must decode to
    /// their literal characters — otherwise multi-line shell-style
    /// commands in custom action configs would land in the daemon
    /// with the backslash + letter visible.
    func testStringEscapesDecoded() {
        let src = """
        [s]
        nl = "line1\\nline2"
        tab = "a\\tb"
        quote = "say \\"hi\\""
        bslash = "C:\\\\path"
        """
        let doc = TOML.parse(src)
        XCTAssertEqual(doc["s"]?["nl"]?.asString, "line1\nline2")
        XCTAssertEqual(doc["s"]?["tab"]?.asString, "a\tb")
        XCTAssertEqual(doc["s"]?["quote"]?.asString, "say \"hi\"")
        XCTAssertEqual(doc["s"]?["bslash"]?.asString, "C:\\path")
    }

    /// Trailing commas in array literals are valid TOML 1.0 and
    /// must not produce a phantom empty element.
    func testTrailingCommaInArray() {
        let src = """
        [s]
        list = ["a", "b", "c", ]
        """
        let doc = TOML.parse(src)
        XCTAssertEqual(doc["s"]?["list"]?.asStringArray, ["a", "b", "c"])
    }

    /// Empty arrays are valid (used to "explicitly nothing" — e.g.
    /// `[exclude] apps = []`). Must decode to `[]`, not nil and not
    /// `[""]`.
    func testEmptyArrayDecodes() {
        let src = """
        [s]
        empty = []
        """
        let doc = TOML.parse(src)
        XCTAssertEqual(doc["s"]?["empty"]?.asStringArray, [])
    }

    /// Comment after a value on the same line: the value parses
    /// and the comment is stripped before parsing kicks in. The
    /// `#` inside a quoted string is preserved (separate test
    /// pins that).
    func testTrailingCommentAfterValue() {
        let src = """
        [s]
        n = 42  # the answer
        """
        let doc = TOML.parse(src)
        XCTAssertEqual(doc["s"]?["n"]?.asInt, 42)
    }

    /// A re-opened section merges into the existing one rather
    /// than replacing it (TOML 1.0 grammar). Our parser must
    /// preserve every key encountered.
    func testReopenedSectionMerges() {
        let src = """
        [a]
        x = 1
        [b]
        y = 2
        [a]
        z = 3
        """
        let doc = TOML.parse(src)
        XCTAssertEqual(doc["a"]?["x"]?.asInt, 1)
        XCTAssertEqual(doc["a"]?["z"]?.asInt, 3)
        XCTAssertEqual(doc["b"]?["y"]?.asInt, 2)
    }
}

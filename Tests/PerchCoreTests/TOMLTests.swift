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
}

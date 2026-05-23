import XCTest
import CoreGraphics
@testable import PerchCore

final class LabelerTests: XCTestCase {

    private func mk(_ n: Int, frames: [CGRect]? = nil) -> [UIElement] {
        (0..<n).map { i in
            UIElement(
                id: "\(i)", role: "Button", label: "btn\(i)",
                frame: frames?[i] ?? CGRect(
                    x: CGFloat(i * 30), y: 0, width: 20, height: 20))
        }
    }

    /// 3 elements + 5-letter alphabet → first three letters, single-char.
    func testSingleLetterAssignment() {
        let elements = mk(3)
        let hints = Labeler.assign(
            elements: elements, alphabet: "abcde",
            prioritiseCenter: false,
            screenSize: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(hints.map(\.keys), ["a", "b", "c"])
    }

    /// More elements than alphabet → spills into two-letter labels.
    /// No single-letter label can be a prefix of a two-letter label.
    func testTwoLetterOverflowDisjointPrefix() {
        let n = 10
        let alphabet = "asd"            // 3 chars
        let elements = mk(n)
        let hints = Labeler.assign(
            elements: elements, alphabet: alphabet,
            prioritiseCenter: false,
            screenSize: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(hints.count, n)
        let singles = Set(hints.map(\.keys).filter { $0.count == 1 })
        let twoLetterPrefixes = Set(
            hints.map(\.keys).filter { $0.count == 2 }
                 .map { String($0.prefix(1)) })
        XCTAssertTrue(singles.intersection(twoLetterPrefixes).isEmpty,
                      "single-letter labels must not collide with "
                      + "two-letter prefixes (\(singles) vs \(twoLetterPrefixes))")
    }

    /// `prioritiseCenter` gives the home-row letters to the element
    /// nearest the screen midpoint.
    func testCenterPriority() {
        let frames = [
            CGRect(x: 0, y: 0, width: 20, height: 20),          // far
            CGRect(x: 490, y: 490, width: 20, height: 20),      // center
            CGRect(x: 800, y: 0, width: 20, height: 20),        // far
        ]
        let elements = mk(3, frames: frames)
        let hints = Labeler.assign(
            elements: elements, alphabet: "asd",
            prioritiseCenter: true,
            screenSize: CGSize(width: 1000, height: 1000))
        // The center element (index 1) should get the first letter
        // 'a' even though it's not first in the input order.
        XCTAssertEqual(hints[1].keys, "a")
    }

    /// `filter(prefix:)` narrows to matches; `resolve(keys:)` requires
    /// exact + unique.
    func testFilterAndResolve() {
        let elements = mk(5)
        let hints = Labeler.assign(
            elements: elements, alphabet: "asdfj",
            prioritiseCenter: false,
            screenSize: CGSize(width: 1000, height: 1000))
        let aMatches = Labeler.filter(hints: hints, prefix: "a")
        XCTAssertEqual(aMatches.count, 1)
        XCTAssertEqual(Labeler.resolve(hints: hints, keys: "a")?.keys, "a")
        XCTAssertNil(Labeler.resolve(hints: hints, keys: "x"))
    }
}

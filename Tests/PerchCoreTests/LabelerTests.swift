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
    ///
    /// 5-letter alphabet × 10 elements: capacity is 5 singles or
    /// 5 × 5 = 25 two-letter combinations, so the labeler reserves
    /// some letters as prefixes and the rest stay single. This
    /// exercises BOTH paths — a labeler that only emitted
    /// single-letter labels would fail; one that always emitted
    /// two-letter labels would fail the disjoint-prefix invariant.
    func testTwoLetterOverflowDisjointPrefix() {
        let n = 10
        let alphabet = "asdfj"          // 5 chars
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
        XCTAssertFalse(singles.isEmpty,
                       "expected at least one single-letter label")
        XCTAssertFalse(twoLetterPrefixes.isEmpty,
                       "expected at least one two-letter label")
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

    /// No elements → no hints. Don't crash, don't return placeholder
    /// labels.
    func testEmptyElementsYieldsEmptyHints() {
        let hints = Labeler.assign(
            elements: [], alphabet: "asdf",
            prioritiseCenter: true,
            screenSize: CGSize(width: 800, height: 600))
        XCTAssertTrue(hints.isEmpty)
    }

    /// Empty alphabet is the same kind of "no work to do" boundary
    /// as no elements — return empty rather than crash.
    func testEmptyAlphabetYieldsEmptyHints() {
        let hints = Labeler.assign(
            elements: mk(3), alphabet: "",
            prioritiseCenter: false,
            screenSize: CGSize(width: 800, height: 600))
        XCTAssertTrue(hints.isEmpty)
    }

    /// 100 elements × default 24-letter alphabet: well within the
    /// two-letter overflow capacity (24 + 23*24 = 576). Every
    /// element should get a unique label; no element should be
    /// dropped silently.
    func testHugeElementSetAllLabeled() {
        let elements = mk(100)
        let hints = Labeler.assign(
            elements: elements,
            alphabet: "asdfjklghqweruiopzxcvbnm",
            prioritiseCenter: false,
            screenSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(hints.count, 100)
        let keys = Set(hints.map(\.keys))
        XCTAssertEqual(keys.count, 100, "expected all labels unique")
    }

    /// `filter` with a prefix that no label starts with → empty.
    /// `resolve` with a non-existent / ambiguous key → nil. These
    /// are the two early-out paths the overlay relies on to
    /// decide between "narrow visible set" vs "fire" vs "miss".
    func testFilterReturnsEmptyForUnknownPrefix() {
        let hints = Labeler.assign(
            elements: mk(3), alphabet: "asd",
            prioritiseCenter: false,
            screenSize: CGSize(width: 800, height: 600))
        XCTAssertTrue(Labeler.filter(hints: hints, prefix: "z").isEmpty)
        // An empty prefix passes everything through — useful for the
        // "fresh overlay, nothing typed yet" state.
        XCTAssertEqual(
            Labeler.filter(hints: hints, prefix: "").count, hints.count)
    }
}

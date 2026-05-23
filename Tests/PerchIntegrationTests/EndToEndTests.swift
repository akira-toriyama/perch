import XCTest
import CoreGraphics
@testable import PerchCore
@testable import PerchAdapterTest

final class EndToEndTests: XCTestCase {

    /// The full Labeler → press pipeline with the synthetic source:
    /// assign labels, simulate the user typing the first hint's key,
    /// and verify that the resolved element's `id` reaches `press`.
    func testLabelAssignmentAndDispatch() {
        let elements = (0..<4).map { i in
            UIElement(
                id: "ui-\(i)",
                role: "Button",
                label: "btn\(i)",
                frame: CGRect(x: CGFloat(i * 40), y: 0,
                              width: 30, height: 30))
        }
        let source = SyntheticUIElementSource(elements: elements)

        let enumerated = source.enumerate()
        let hints = Labeler.assign(
            elements: enumerated, alphabet: "asdf",
            prioritiseCenter: false,
            screenSize: CGSize(width: 1000, height: 1000))
        XCTAssertEqual(hints.count, 4)
        XCTAssertEqual(hints.map(\.keys), ["a", "s", "d", "f"])

        // Simulate the user typing 'a' — should resolve to element 0.
        let resolved = Labeler.resolve(hints: hints, keys: "a")
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.element.id, "ui-0")

        // Dispatch path: source.press records the call.
        _ = source.press(id: resolved!.element.id)
        XCTAssertEqual(source.pressed, ["ui-0"])
    }

    /// Failure path: `press` returning `false` is surfaced to the
    /// caller (the controller logs "AXPress failed" — this just
    /// verifies the return propagates).
    func testPressFailurePropagates() {
        let elements = [UIElement(
            id: "x", role: "Button", label: "nope",
            frame: CGRect(x: 0, y: 0, width: 10, height: 10))]
        let source = SyntheticUIElementSource(elements: elements)
        source.pressResult = false
        XCTAssertFalse(source.press(id: "x"))
    }
}

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

        // Dispatch path: source.act records the call.
        _ = source.act(id: resolved!.element.id, as: .press)
        XCTAssertEqual(source.actions.count, 1)
        XCTAssertEqual(source.actions.first?.id, "ui-0")
        XCTAssertEqual(source.actions.first?.action, .press)
    }

    /// Failure path: `act` returning `false` is surfaced to the
    /// caller (the controller logs the failure — this just
    /// verifies the return propagates).
    func testActFailurePropagates() {
        let elements = [UIElement(
            id: "x", role: "Button", label: "nope",
            frame: CGRect(x: 0, y: 0, width: 10, height: 10))]
        let source = SyntheticUIElementSource(elements: elements)
        source.actResult = false
        XCTAssertFalse(source.act(id: "x", as: .press))
    }

    /// Each action variant routes through `act` with the expected
    /// tag so adapter implementations can map them to AX calls.
    func testAllActionVariantsRecorded() {
        let elements = [UIElement(
            id: "ui", role: "Button", label: "ok",
            frame: CGRect(x: 0, y: 0, width: 10, height: 10))]
        let source = SyntheticUIElementSource(elements: elements)
        _ = source.act(id: "ui", as: .press)
        _ = source.act(id: "ui", as: .rightClick)
        _ = source.act(id: "ui", as: .copyTitle)
        _ = source.act(id: "ui", as: .focus)
        XCTAssertEqual(
            source.actions.map(\.action),
            [.press, .rightClick, .copyTitle, .focus])
    }
}

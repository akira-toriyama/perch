// Drop-in `UIElementSource` for tests. Feeds a fixed array of
// elements and records every `press(id:)` call so the integration
// suite can assert the dispatch path end-to-end without touching a
// real AX tree.

import CoreGraphics
import Foundation
import PerchCore

public final class SyntheticUIElementSource: UIElementSource, @unchecked Sendable {

    public let elements: [UIElement]

    /// Recorded ids passed to `press(id:)`, oldest first.
    public private(set) var pressed: [String] = []

    /// Optional pre-set return value for `press(id:)`. Defaults to
    /// `true` (success). Set to `false` to drive the
    /// "AXPress failed" path in tests.
    public var pressResult: Bool = true

    public init(elements: [UIElement]) {
        self.elements = elements
    }

    public func enumerate() -> [UIElement] { elements }

    public func press(id: String) -> Bool {
        pressed.append(id)
        return pressResult
    }
}

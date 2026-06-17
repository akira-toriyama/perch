// Drop-in `UIElementSource` for tests. Feeds a fixed array of
// elements and records every `act(id:as:)` call so the integration
// suite can assert the dispatch path end-to-end without touching a
// real AX tree.

import CoreGraphics
import Foundation
import PerchCore

public final class SyntheticUIElementSource: UIElementSource, @unchecked Sendable {

    public let elements: [UIElement]

    /// Recorded `(id, action)` tuples passed to `act`, oldest first.
    /// Tests assert on this to verify the action-mode dispatch.
    public private(set) var actions: [(id: String, action: HintAction)] = []

    /// Optional pre-set return value for `act(id:as:)`. Defaults
    /// to `true` (success). Set to `false` to drive the
    /// "AX action failed" path in tests.
    public var actResult: Bool = true

    public init(elements: [UIElement]) {
        self.elements = elements
    }

    public func enumerate() -> [UIElement] { elements }

    public func act(id: String, as action: HintAction) -> Bool {
        actions.append((id: id, action: action))
        return actResult
    }
}

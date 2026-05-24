// The seam that lets the Controller see clickable UI elements
// without knowing about AX. Real impl: AXUIElementSource (in
// PerchAdapterMacOS). Test impl: SyntheticUIElementSource (in
// PerchAdapterTest) — feeds canned elements for the labeling /
// dispatch pipeline.

import Foundation

public protocol UIElementSource: AnyObject, Sendable {
    /// Enumerate every labelable UI element in the frontmost
    /// app's focused window. Adapters apply the role allow-list
    /// declared in `PerchConfig.roles` before returning.
    ///
    /// Returns an empty array if there is no eligible frontmost
    /// window (Finder desktop, Dock, etc.) — the controller then
    /// silently dismisses hint mode instead of showing an empty
    /// overlay.
    func enumerate() -> [UIElement]

    /// Perform `action` against the element identified by `id`.
    /// The id was produced by the most recent `enumerate()` call;
    /// live AX handles are kept adapter-side. Returns `false`
    /// when the underlying AX call refuses (most often: the
    /// element doesn't support the requested action).
    func act(id: String, as action: HintAction) -> Bool
}

public extension UIElementSource {
    /// Shorthand for the default `.press` action. Tests written
    /// before action-modes use this; new callers should pass the
    /// explicit action.
    func press(id: String) -> Bool {
        act(id: id, as: .press)
    }
}

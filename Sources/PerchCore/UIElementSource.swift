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

    /// Enumerate large containers — Group / Article / Section /
    /// SplitGroup / ScrollArea / Image / Landmark — for regional
    /// hint mode (issue #34). Unlike `enumerate()` this does NOT
    /// require `kAXPressAction` support, since regional picks are
    /// typically for `.copyTitle` / `.focus` / `.rightClick`
    /// against non-clickable containers (an article body, a
    /// sidebar pane, an embedded image). Min frame size is the
    /// gate that keeps "large containers only" honest.
    ///
    /// Returns `[]` from the default implementation so adapters
    /// that don't need regional support (`SyntheticUIElementSource`)
    /// don't have to implement it. `AXUIElementSource` overrides
    /// with the real walk.
    func enumerateRegions() -> [UIElement]

    /// Enumerate every menu-bar item in the frontmost app (issue
    /// #52). Walks `kAXMenuBarAttribute` recursively → each
    /// pressable leaf is emitted with the full menu path as its
    /// `label` (`"File > Save As…"`). Frames come back as `.zero`
    /// because AX doesn't position closed menu items — consumers
    /// must render menu matches in a list (not pinned to a frame).
    ///
    /// Returns `[]` from the default implementation; adapters that
    /// don't navigate menus (`SyntheticUIElementSource`) inherit
    /// the no-op.
    func enumerateMenu() -> [UIElement]

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

    /// Default: regional mode opts in. Sources without a meaningful
    /// region notion (synthetic tests, future backends that don't
    /// expose containers) get an empty list, and the Controller
    /// silently dismisses the regional overlay — same fall-open
    /// behaviour as `enumerate()` returning `[]`.
    func enumerateRegions() -> [UIElement] { [] }

    /// Default: menu mode opts in. A synthetic source without a
    /// modelled menu bar returns `[]` — Controller dismisses the
    /// menu overlay silently.
    func enumerateMenu() -> [UIElement] { [] }
}

// Backend-neutral data types crossing the Core/Adapter seam.
//
// `UIElement` describes a clickable thing in the frontmost app: its
// on-screen frame (so the overlay can position a label), a role tag,
// an optional title (for debugging / diagnostics), and an opaque
// `id` the adapter uses to look the live AX handle up at dispatch
// time. Core must never touch AX directly — same policy as facet's
// `Window` vs adapter-side `RFWorkspace`.

import CoreGraphics
import Foundation

/// One clickable UI element the overlay can label. Identity is the
/// `id` field — the adapter keeps a side-table keyed on it so the
/// live `AXUIElement` doesn't have to enter Core.
public struct UIElement: Sendable, Hashable {
    /// Adapter-opaque identifier. For PerchAdapterMacOS it's a
    /// concatenation of `(pid, address)` of the AXUIElement so a
    /// dispatcher round-trip can resolve it back. Test adapter is
    /// free to use anything stable across a single enumeration.
    public let id: String

    /// AX role without the `AX` prefix ("Button", "Link", …).
    public let role: String

    /// AX title / value for debugging. Not shown in the overlay.
    public let label: String

    /// On-screen frame in screen coordinates (top-left origin).
    public let frame: CGRect

    /// AX-bound keyboard shortcut (issue #58), pre-formatted with
    /// the macOS modifier glyphs in the canonical order
    /// (`⌃⌥⇧⌘<key>`). `nil` when the element has no associated
    /// shortcut OR the adapter didn't populate it.
    ///
    /// Today `AXUIElementSource.enumerateMenu()` is the only call
    /// site that reads `kAXMenuItemCmdChar` / `kAXMenuItemCmdModifiers`
    /// to fill this in — toolbar / window / emoji / hint walkers
    /// leave it `nil`. The renderer (SearchCanvas) hides the
    /// annotation when this is nil, so a `nil` here costs nothing
    /// at draw time.
    public let shortcut: String?

    public init(
        id: String, role: String, label: String,
        frame: CGRect, shortcut: String? = nil
    ) {
        self.id = id
        self.role = role
        self.label = label
        self.frame = frame
        self.shortcut = shortcut
    }
}

/// A label assigned by the Labeler to a UIElement. `keys` is the
/// sequence the user must type to trigger this element (e.g. "a",
/// "as", "jk"). The overlay renders `keys` on top of the element at
/// `frame`'s top-left corner.
public struct Hint: Sendable, Hashable {
    public let keys: String
    public let element: UIElement
    public init(keys: String, element: UIElement) {
        self.keys = keys
        self.element = element
    }
}

/// What perch does with the element a hint resolves to. Selected
/// by which modifier (if any) the user holds while typing the
/// resolving label — see [hotkey] in the README for the bindings.
public enum HintAction: String, Sendable, CaseIterable {
    /// Default — AX `kAXPressAction`. Behaves like a left-click.
    case press
    /// Shift-held — AX `kAXShowMenuAction`. Opens the element's
    /// context menu (the keyboard analogue of a right-click).
    case rightClick
    /// Cmd-held — copy the element's title / label text to the
    /// system pasteboard. Useful for grabbing the visible name of
    /// a control without retyping it.
    case copyTitle
    /// Alt-held — set AX `kAXFocusedAttribute` to true. Moves
    /// keyboard focus to the element without firing its action.
    /// Right for text fields you intend to type into.
    case focus
    /// Cmd+Shift-held — same AX dispatch as `.press`, but the
    /// controller re-shows hints after firing so the user can
    /// chain multiple actions (open 5 issues in a row, close 8
    /// notifications, etc.) without re-pressing the hotkey
    /// between each. Exit via Esc / cancel-key / hotkey-again.
    /// Surfingkeys-style `cf` (continuous follow).
    case pressContinuous
    /// Chord `,o` (issue #57) — reveal the element's file URL
    /// (Finder selection). Only meaningful for AX elements that
    /// expose `kAXURLAttribute` pointing at a `file://` URL —
    /// e.g. Finder selection, Safari downloads list. Otherwise
    /// dispatch logs + returns false.
    case revealInFinder
    /// Chord `,u` (issue #57) — copy the element's `kAXURLAttribute`
    /// to the pasteboard. Lets you grab a link without
    /// right-clicking → Copy Link.
    case copyURL
    /// Chord `,s` (issue #57) — speak the element's title via
    /// `AVSpeechSynthesizer`. Accessibility / proofreading use.
    case speakTitle
}

/// Parsed `[hotkey].combo` value.
public struct HotkeyCombo: Sendable, Equatable {
    public let modifiers: Modifiers
    public let key: String          // canonical lowercase ("space", "j", "f1")

    public struct Modifiers: OptionSet, Sendable, Hashable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let shift = Modifiers(rawValue: 1 << 0)
        public static let ctrl  = Modifiers(rawValue: 1 << 1)
        public static let alt   = Modifiers(rawValue: 1 << 2)
        public static let cmd   = Modifiers(rawValue: 1 << 3)
    }

    public init(modifiers: Modifiers, key: String) {
        self.modifiers = modifiers
        self.key = key
    }

    /// Parse `"shift+space"` / `"ctrl+alt+j"` etc. Order-insensitive,
    /// case-insensitive. Returns `nil` on a malformed string — caller
    /// (Config) is expected to fall back to the default.
    public static func parse(_ s: String) -> HotkeyCombo? {
        let parts = s.lowercased().split(separator: "+").map(String.init)
        guard let last = parts.last, !last.isEmpty else { return nil }
        var mods: Modifiers = []
        for p in parts.dropLast() {
            switch p {
            case "shift": mods.insert(.shift)
            case "ctrl", "control": mods.insert(.ctrl)
            case "alt", "opt", "option": mods.insert(.alt)
            case "cmd", "command", "meta": mods.insert(.cmd)
            default: return nil
            }
        }
        return HotkeyCombo(modifiers: mods, key: last)
    }
}

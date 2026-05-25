import XCTest
@testable import PerchAdapterMacOS

final class HotkeyMonitorTests: XCTestCase {

    /// Every name that appears in `HotkeyMonitor.keyCode(for:)`
    /// — and the cancel-key vocabulary `OverlayWindow` depends on —
    /// must resolve to a non-nil keycode. A change that drops one
    /// of these silently breaks `[hotkey].active` / `[hotkey].cancel`
    /// for users who'd been relying on it.
    func testAllDocumentedKeyNamesResolve() {
        let expected: [String] = [
            "space", "return", "enter", "esc", "escape",
            "tab", "delete", "backspace",
            "f1", "f2", "f3", "f4", "f5", "f6",
            "f7", "f8", "f9", "f10", "f11", "f12",
            "a", "b", "c", "d", "e", "f", "g", "h", "i", "j",
            "k", "l", "m", "n", "o", "p", "q", "r", "s", "t",
            "u", "v", "w", "x", "y", "z",
        ]
        for name in expected {
            XCTAssertNotNil(
                HotkeyMonitor.keyCode(for: name),
                "expected keycode for documented name \"\(name)\"")
        }
    }

    /// Unknown / malformed key names return nil so the caller
    /// (Config) can fall back to the default rather than crash.
    func testUnknownKeyNameReturnsNil() {
        let unknowns = ["frobnicate", "", "A", "F13", "Space"]
        for name in unknowns {
            XCTAssertNil(
                HotkeyMonitor.keyCode(for: name),
                "expected nil for unknown name \"\(name)\"")
        }
    }

    /// `esc` and `escape` map to the SAME keycode (53 = kVK_Escape)
    /// so users can write either form in `[hotkey].cancel`.
    /// Similarly for `return` / `enter`, `delete` / `backspace`.
    func testKeyNameAliases() {
        XCTAssertEqual(
            HotkeyMonitor.keyCode(for: "esc"),
            HotkeyMonitor.keyCode(for: "escape"))
        XCTAssertEqual(
            HotkeyMonitor.keyCode(for: "return"),
            HotkeyMonitor.keyCode(for: "enter"))
        XCTAssertEqual(
            HotkeyMonitor.keyCode(for: "delete"),
            HotkeyMonitor.keyCode(for: "backspace"))
    }
}

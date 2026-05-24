import XCTest
@testable import PerchCore

final class ConfigTests: XCTestCase {

    func testDefaultsWhenFileMissing() {
        let cfg = PerchConfig.parse("")
        XCTAssertEqual(cfg.hotkey, PerchConfig.defaultHotkey)
        XCTAssertEqual(cfg.cancelKey, PerchConfig.defaultCancelKey)
        XCTAssertEqual(cfg.alphabet, PerchConfig.defaultAlphabet)
        XCTAssertEqual(cfg.overlayBackground, "#fde047")
        XCTAssertEqual(cfg.overlayDim, 0.25, accuracy: 0.0001)
        XCTAssertTrue(cfg.autoClickOnUnique)
    }

    func testCancelKeyParsing() {
        let src = """
        [hotkey]
        cancel = "q"
        """
        XCTAssertEqual(PerchConfig.parse(src).cancelKey, "q")
        // Empty / whitespace falls back to default.
        XCTAssertEqual(
            PerchConfig.parse("[hotkey]\ncancel = \"  \"").cancelKey,
            PerchConfig.defaultCancelKey)
    }

    func testHotkeyParsing() {
        XCTAssertEqual(
            HotkeyCombo.parse("shift+space"),
            HotkeyCombo(modifiers: .shift, key: "space"))
        XCTAssertEqual(
            HotkeyCombo.parse("Cmd+Alt+J"),
            HotkeyCombo(modifiers: [.cmd, .alt], key: "j"))
        XCTAssertNil(HotkeyCombo.parse(""))
        XCTAssertNil(HotkeyCombo.parse("frob+j"))
    }

    /// Out-of-range values clamp instead of erroring — same "typo
    /// can't break the daemon" policy stroke / facet enforce.
    func testValuesClampInsteadOfReject() {
        let src = """
        [overlay]
        font-size = 999
        dim = 5.0
        background = "not-a-color"
        """
        let cfg = PerchConfig.parse(src)
        XCTAssertEqual(cfg.overlayFontSize, 32)         // clamped to max
        XCTAssertEqual(cfg.overlayDim, 0.6, accuracy: 0.0001)
        XCTAssertEqual(cfg.overlayBackground, "#fde047")  // bad → default
    }

    /// Alphabet duplicates and non-letters are silently dropped.
    func testAlphabetSanitisation() {
        let src = """
        [labels]
        alphabet = "aaa BCB-12"
        """
        let cfg = PerchConfig.parse(src)
        XCTAssertEqual(cfg.alphabet, "abc")
    }

    func testRoleArrayParses() {
        let src = """
        [behavior]
        roles = ["Button", "Link"]
        exclude-apps = ["com.evil.app"]
        """
        let cfg = PerchConfig.parse(src)
        XCTAssertEqual(cfg.roles, ["Button", "Link"])
        XCTAssertEqual(cfg.excludeApps, ["com.evil.app"])
    }
}

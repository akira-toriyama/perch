import XCTest
import ConfigSchema
@testable import PerchCore

/// #1 of the config-DRY A3 work (t-5qxd): every `default:` the spec emits is
/// DERIVED from `PerchConfig.default` (the one built-in-defaults source), not a
/// hand-copied literal — so the *shown* default (editor completion /
/// `config --emit-schema`) can never drift from the *resolved* default.
///
/// `DefaultDriftTests` locks the resolved path (`parse("") == .default`); this
/// locks the shown path (`Field.def == .default.<path>`). A regression that
/// re-hardcodes a spec `default:` literal disagreeing with `.default` — which
/// `ConfigSchemaDriftTests` (committed == emitted) can't see, since both sides
/// move together — fails HERE.
///
/// Representative coverage: one field per `DefaultValue` case (string / bool /
/// number / int / stringArray / enum-as-rawValue-string) across sections, plus
/// the two knobs central to this task (`color-cycle-seconds`, `timeout-ms`).
///
/// `hotkey.active` stays a literal (a descOnly schema example; `HotkeyCombo` has
/// no String serializer to derive it from, and there's no consumer yet to earn
/// one — rule-of-three). It can't be locked by equality, but a parse-round-trip
/// guard below asserts the advertised string still parses to
/// `.default.hotkey.active` — catching drift without a serializer.
/// `labels.alphabet` / `behavior.roles` need no guard: they already reference
/// the shared `defaultAlphabet` / `defaultRoles` consts `.default` itself uses.
final class SchemaDefaultDerivationTests: XCTestCase {

    private func def(_ section: String, _ key: String) -> ConfigSchema.DefaultValue? {
        PerchConfig.configSpec
            .sections.first { $0.header == section }?
            .fields.first { $0.key == key }?.def
    }

    func testSchemaDefaultsAreDerivedFromBuiltIn() {
        let d = PerchConfig.default
        // string
        XCTAssertEqual(def("hotkey", "cancel"), .string(d.hotkey.cancel))
        // bool
        XCTAssertEqual(def("overlay", "blur-enabled"), .bool(d.overlay.blurEnabled))
        // number (Double)
        XCTAssertEqual(def("overlay", "font-size"), .number(d.overlay.fontSize))
        // enum → rawValue string
        XCTAssertEqual(def("overlay", "pill-shape"), .string(d.overlay.pillShape.rawValue))
        // int
        XCTAssertEqual(def("grid", "cols"), .int(d.grid.cols))
        // stringArray
        XCTAssertEqual(def("exclude", "apps"), .stringArray(d.behavior.excludeApps))
        // the two knobs this task centered on (shown == resolved, no unit gap)
        XCTAssertEqual(def("overlay.border", "color-cycle-seconds"),
                       .number(d.border.cycleSeconds))
        XCTAssertEqual(def("overlay.border", "effect"),
                       .string(d.border.effect.rawValue))
        XCTAssertEqual(def("chord", "timeout-ms"), .number(d.chord.timeoutMs))
    }

    /// `hotkey.active` is the one schema default kept as a literal (a descOnly
    /// example; `HotkeyCombo` has no `parse` inverse to derive it from). Guard
    /// it can't silently drift from the real built-in: the advertised default
    /// string must parse back to `.default.hotkey.active`.
    func testActiveSchemaDefaultParsesToBuiltIn() {
        guard case .string(let shown)? = def("hotkey", "active") else {
            return XCTFail("hotkey.active should carry a string schema default")
        }
        XCTAssertEqual(HotkeyCombo.parse(shown), PerchConfig.default.hotkey.active)
    }
}

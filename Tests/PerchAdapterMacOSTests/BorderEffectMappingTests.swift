import XCTest
import Effects
import PerchCore

/// Guards the sill-1.10 border convergence. perch's `[overlay.border]`
/// presets no longer carry their own hue table — each `BorderEffect`
/// case is resolved to a shared sill `EffectSpec` BY NAME
/// (`borderEffectFor(rawValue)`) and drawn with sill's `resolveBorder`.
/// If perch's case names and sill's catalog names ever drift apart the
/// lookup silently returns nil and the border vanishes; these tests fail
/// loudly instead. (Same spirit as `HotkeyMonitorTests` for key names.)
///
/// `swift test` needs full Xcode/XCTest, so this runs in CI — not on the
/// maintainer's CommandLineTools-only box.
final class BorderEffectMappingTests: XCTestCase {

    /// Every selectable preset (`.off` and `.random` aside) must map to a
    /// concrete sill `EffectSpec`. `.random` resolves to one of these at
    /// runtime, so covering the concrete cases covers it too.
    func testEverySelectablePresetResolvesInSillCatalog() {
        for effect in BorderEffect.allCases where effect != .off && effect != .random {
            XCTAssertNotNil(
                borderEffectFor(effect.rawValue),
                "BorderEffect.\(effect.rawValue) must resolve to a sill EffectSpec — "
                    + "perch's case name drifted from sill's Effects catalog")
        }
    }

    /// `.off` carries no effect: the catalog returns nil so the overlay
    /// keeps its plain accent hairline.
    func testOffResolvesToNoSpec() {
        XCTAssertNil(borderEffectFor(BorderEffect.off.rawValue))
    }

    /// `.random` always settles on a drawable (non-off, non-random)
    /// preset that itself resolves in sill's catalog.
    func testRandomResolvesToADrawablePreset() {
        for _ in 0 ..< 32 {
            let resolved = BorderEffect.random.resolvingRandom()
            XCTAssertNotEqual(resolved, .off)
            XCTAssertNotEqual(resolved, .random)
            XCTAssertNotNil(
                borderEffectFor(resolved.rawValue),
                "BorderEffect.random resolved to \(resolved.rawValue), "
                    + "which must also resolve in sill's catalog")
        }
    }
}

import XCTest
@testable import PerchCore

/// perch's built-in defaults have ONE source: `PerchConfig.default` ("what
/// perch does with no config file"). The decode-staging seeds
/// (`PerchConfig.Staged`) are now read from it, so parsing an EMPTY config
/// must reproduce `.default` exactly for every uniform scalar — the
/// "resolved via empty-parse" and "resolved via no-file" paths can no longer
/// drift. This locks that: re-hardcoding a `Staged` seed (or editing
/// `.default`'s assembly) so the two disagree fails here. (A3 DRY — t-5qxd.)
///
/// NOTE: this asserts the RESOLVED-default path (empty-parse == `.default`).
/// The *shown* default (each spec field's emitted `def:`) is locked to
/// `.default` separately by `SchemaDefaultDerivationTests` (t-5qxd A3 #1).
/// The former unit gap — `color-cycle-ms = 3000` emitted vs `cycleSeconds =
/// 3.0` resolved — is CLOSED: the knob is now `color-cycle-seconds` (seconds
/// in config AND runtime), so shown == resolved with no unit bridge.
final class DefaultDriftTests: XCTestCase {

    func testEmptyParseEqualsBuiltInDefault() {
        let r = PerchConfig.parse("")     // resolved-via-empty-parse
        let d = PerchConfig.default        // resolved-via-no-file (the source)

        // [hotkey] (active is bespoke grammar — covered elsewhere)
        XCTAssertEqual(r.hotkey.cancel, d.hotkey.cancel)
        // [labels] (alphabet is bespoke)
        XCTAssertEqual(r.labels.prioritiseCenter, d.labels.prioritiseCenter)
        // [overlay] uniform scalars (theme / modifier-badge are bespoke)
        XCTAssertEqual(r.overlay.accent, d.overlay.accent)
        XCTAssertEqual(r.overlay.pillShape, d.overlay.pillShape)
        XCTAssertEqual(r.overlay.fontSize, d.overlay.fontSize)
        XCTAssertEqual(r.overlay.blurEnabled, d.overlay.blurEnabled)
        XCTAssertEqual(r.overlay.animEnabled, d.overlay.animEnabled)
        XCTAssertEqual(r.overlay.showShortcuts, d.overlay.showShortcuts)
        XCTAssertEqual(r.overlay.peekKey, d.overlay.peekKey)
        // [overlay.effect]
        XCTAssertEqual(r.effect.appear, d.effect.appear)
        XCTAssertEqual(r.effect.match, d.effect.match)
        XCTAssertEqual(r.effect.unmatch, d.effect.unmatch)
        XCTAssertEqual(r.effect.narrow, d.effect.narrow)
        XCTAssertEqual(r.effect.intensity, d.effect.intensity)
        XCTAssertEqual(r.effect.durationScale, d.effect.durationScale)
        // [overlay.border]
        XCTAssertEqual(r.border.effect, d.border.effect)
        XCTAssertEqual(r.border.glow, d.border.glow)
        XCTAssertEqual(r.border.width, d.border.width)
        XCTAssertEqual(r.border.cycleSeconds, d.border.cycleSeconds)
        // [overlay.sound]
        XCTAssertEqual(r.sound.match, d.sound.match)
        XCTAssertEqual(r.sound.unmatch, d.sound.unmatch)
        XCTAssertEqual(r.sound.activate, d.sound.activate)
        XCTAssertEqual(r.sound.volume, d.sound.volume)
        // [behavior] uniform scalars (roles / web-roles / per-app are bespoke)
        XCTAssertEqual(r.behavior.autoClickOnUnique, d.behavior.autoClickOnUnique)
        XCTAssertEqual(r.behavior.minSize, d.behavior.minSize)
        XCTAssertEqual(r.behavior.excludeApps, d.behavior.excludeApps)
        // [regional]
        XCTAssertEqual(r.regional.minWidth, d.regional.minWidth)
        XCTAssertEqual(r.regional.minHeight, d.regional.minHeight)
        // [grid]
        XCTAssertEqual(r.grid.cols, d.grid.cols)
        XCTAssertEqual(r.grid.rows, d.grid.rows)
        XCTAssertEqual(r.grid.recursiveCols, d.grid.recursiveCols)
        XCTAssertEqual(r.grid.recursiveRows, d.grid.recursiveRows)
        XCTAssertEqual(r.grid.maxDepth, d.grid.maxDepth)
        XCTAssertEqual(r.grid.nestMinSize, d.grid.nestMinSize)
        // [chord] (leader is bespoke)
        XCTAssertEqual(r.chord.timeoutMs, d.chord.timeoutMs)
    }
}

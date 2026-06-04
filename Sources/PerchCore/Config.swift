// Typed view over the user's `~/.config/perch/config.toml`. The
// app only ever READS this file — no auto-generation, no runtime
// override persistence (same policy as stroke / facet).
//
// All accessors clamp out-of-range / unknown values to defaults
// instead of rejecting, so a typo in one key can't take down the
// whole daemon.

import CoreGraphics
import Foundation

public struct PerchConfig: Sendable {

    // MARK: - [hotkey]

    public let hotkey: HotkeyCombo

    /// Name of the key that dismisses an active overlay (single
    /// key, no modifiers). Default `"esc"`. Canonical list lives
    /// in `HotkeyMonitor.keyCode(for:)` — values that don't
    /// resolve there silently fall back to `"esc"`.
    public let cancelKey: String

    // MARK: - [labels]

    public let alphabet: String
    public let prioritiseCenter: Bool

    // MARK: - [overlay]

    /// Accent colour used for the typed-prefix highlight, the active
    /// hint border, and the glow. `"system"` resolves to the user's
    /// macOS accent colour (`NSColor.controlAccentColor`); a `#rrggbb`
    /// literal overrides. Same colour vocabulary as stroke's overlay.
    public let overlayAccent: String

    public let overlayFontSize: Double

    /// `true` to layer a `NSVisualEffectView` (`.hudWindow`,
    /// `.behindWindow`) under the hint pills — the frosted-glass look.
    /// `false` falls back to solid dark fills so the design degrades
    /// gracefully on systems where blur is disabled by Accessibility
    /// preferences or for performance.
    public let overlayBlurEnabled: Bool

    /// `true` to play the 150ms scale-in animation on appear and the
    /// 200ms red flash on a missed keypress. `false` for users who
    /// have Reduce Motion enabled or just dislike effects.
    public let overlayAnimEnabled: Bool

    // MARK: - [behavior]

    public let autoClickOnUnique: Bool
    public let roles: [String]
    public let excludeApps: [String]

    /// Skip AX elements whose frame is smaller than this on either
    /// axis (points). Defaults to 6 — the historical "skip a 1×1
    /// hidden anchor" floor. Raise to declutter icon-only toolbars
    /// (Chrome's 16×16 window controls fall out at 20). Clamped to
    /// `>= 0`; 0 disables the check entirely.
    public let minSize: Double

    // MARK: - Constants

    /// Resolved path of the user's config file.
    public static let path: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/perch/config.toml"
    }()

    // MARK: - Defaults

    public static let defaultHotkey = HotkeyCombo(
        modifiers: .shift, key: "space")
    public static let defaultCancelKey = "esc"
    public static let defaultAlphabet = "asdfjklghqweruiopzxcvbnm"
    public static let defaultRoles = [
        "Button", "MenuItem", "MenuButton", "CheckBox",
        "RadioButton", "PopUpButton", "Link", "TabGroup",
        "Tab", "TextField", "SearchField",
    ]

    /// Built-in defaults — what perch does when no config file exists.
    public static let `default` = PerchConfig(
        hotkey: defaultHotkey,
        cancelKey: defaultCancelKey,
        alphabet: defaultAlphabet,
        prioritiseCenter: true,
        overlayAccent: "system",
        overlayFontSize: 15,
        overlayBlurEnabled: true,
        overlayAnimEnabled: true,
        autoClickOnUnique: true,
        roles: defaultRoles,
        excludeApps: [],
        minSize: 6
    )

    // MARK: - Load / parse

    /// Read the config file from disk and return a fully-resolved
    /// `PerchConfig`. Missing file → all defaults. Malformed values
    /// silently clamp to defaults.
    public static func load() -> PerchConfig {
        let source = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        if source.isEmpty {
            return .default
        }
        return parse(source)
    }

    /// Parse a config source string. Public so tests can drive the
    /// clamping rules directly without touching disk.
    public static func parse(_ source: String) -> PerchConfig {
        let doc = TOML.parse(source)

        let hk = doc["hotkey"]?["active"]?.asString
            .flatMap(HotkeyCombo.parse) ?? defaultHotkey
        let cancel = (doc["hotkey"]?["cancel"]?.asString)
            .flatMap { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? defaultCancelKey

        let alphabet = (doc["labels"]?["alphabet"]?.asString)
            .flatMap { sanitiseAlphabet($0) } ?? defaultAlphabet
        let priority = doc["labels"]?["prioritise-center"]?.asBool ?? true

        // Accept "system", a CSS-style colour name (subset that maps
        // to NSColor.system*), or a `#rrggbb` literal. Anything else
        // falls back to "system" so a typo never erases the accent.
        let accent = (doc["overlay"]?["accent"]?.asString)
            .flatMap(sanitiseAccent) ?? "system"
        let size = (doc["overlay"]?["font-size"]?.asDouble).map {
            min(max($0, 8), 32)
        } ?? 15
        let blur = doc["overlay"]?["blur-enabled"]?.asBool ?? true
        let anim = doc["overlay"]?["anim-enabled"]?.asBool ?? true

        let autoClick = doc["behavior"]?["auto-click-on-unique"]?.asBool ?? true
        let roles = (doc["behavior"]?["roles"]?.asStringArray)
            .map { $0.filter { !$0.isEmpty } } ?? defaultRoles
        let excludes = doc["behavior"]?["exclude-apps"]?.asStringArray ?? []
        // Clamp negatives to 0 (per typo-tolerance policy);
        // 0 disables the size floor entirely.
        let minSize = (doc["behavior"]?["min-size"]?.asDouble).map {
            max(0, $0)
        } ?? 6

        return PerchConfig(
            hotkey: hk,
            cancelKey: cancel,
            alphabet: alphabet,
            prioritiseCenter: priority,
            overlayAccent: accent,
            overlayFontSize: size,
            overlayBlurEnabled: blur,
            overlayAnimEnabled: anim,
            autoClickOnUnique: autoClick,
            roles: roles,
            excludeApps: excludes,
            minSize: minSize)
    }

    /// Drop duplicates and non-typeable characters, lowercase the
    /// result. Empty after sanitising → fall back to the default
    /// alphabet (returns `nil` so the call site can apply the
    /// default).
    private static func sanitiseAlphabet(_ s: String) -> String? {
        var seen = Set<Character>()
        var out = ""
        for ch in s.lowercased() {
            guard ch.isLetter, !seen.contains(ch) else { continue }
            seen.insert(ch)
            out.append(ch)
        }
        return out.isEmpty ? nil : out
    }

    /// Accept "system" (system accent colour) or a `#rrggbb`
    /// literal. Returns the canonical lowercase form, or `nil` on a
    /// malformed input so the caller can clamp to the default.
    private static func sanitiseAccent(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "system" || t == "accent" { return "system" }
        guard t.hasPrefix("#"), t.count == 7,
              t.dropFirst().allSatisfy({ "0123456789abcdef".contains($0) })
        else { return nil }
        return t
    }
}

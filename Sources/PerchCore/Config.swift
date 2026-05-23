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

    // MARK: - [labels]

    public let alphabet: String
    public let prioritiseCenter: Bool

    // MARK: - [overlay]

    public let overlayBackground: String
    public let overlayForeground: String
    public let overlayFontSize: Double
    public let overlayDim: Double

    // MARK: - [behavior]

    public let autoClickOnUnique: Bool
    public let roles: [String]
    public let excludeApps: [String]

    // MARK: - Constants

    /// Resolved path of the user's config file.
    public static let path: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/perch/config.toml"
    }()

    // MARK: - Defaults

    public static let defaultHotkey = HotkeyCombo(
        modifiers: .shift, key: "space")
    public static let defaultAlphabet = "asdfjklghqweruiopzxcvbnm"
    public static let defaultRoles = [
        "Button", "MenuItem", "MenuButton", "CheckBox",
        "RadioButton", "PopUpButton", "Link", "TabGroup",
        "Tab", "TextField", "SearchField",
    ]

    /// Built-in defaults — what perch does when no config file exists.
    public static let `default` = PerchConfig(
        hotkey: defaultHotkey,
        alphabet: defaultAlphabet,
        prioritiseCenter: true,
        overlayBackground: "#fde047",
        overlayForeground: "#1f2937",
        overlayFontSize: 14,
        overlayDim: 0.25,
        autoClickOnUnique: true,
        roles: defaultRoles,
        excludeApps: []
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

        let hk = doc["hotkey"]?["combo"]?.asString
            .flatMap(HotkeyCombo.parse) ?? defaultHotkey

        let alphabet = (doc["labels"]?["alphabet"]?.asString)
            .flatMap { sanitiseAlphabet($0) } ?? defaultAlphabet
        let priority = doc["labels"]?["prioritise-center"]?.asBool ?? true

        let bg = (doc["overlay"]?["background"]?.asString)
            .flatMap(sanitiseHex) ?? "#fde047"
        let fg = (doc["overlay"]?["foreground"]?.asString)
            .flatMap(sanitiseHex) ?? "#1f2937"
        let size = (doc["overlay"]?["font-size"]?.asDouble).map {
            min(max($0, 8), 32)
        } ?? 14
        let dim = (doc["overlay"]?["dim"]?.asDouble).map {
            min(max($0, 0), 0.6)
        } ?? 0.25

        let autoClick = doc["behavior"]?["auto-click-on-unique"]?.asBool ?? true
        let roles = (doc["behavior"]?["roles"]?.asStringArray)
            .map { $0.filter { !$0.isEmpty } } ?? defaultRoles
        let excludes = doc["behavior"]?["exclude-apps"]?.asStringArray ?? []

        return PerchConfig(
            hotkey: hk,
            alphabet: alphabet,
            prioritiseCenter: priority,
            overlayBackground: bg,
            overlayForeground: fg,
            overlayFontSize: size,
            overlayDim: dim,
            autoClickOnUnique: autoClick,
            roles: roles,
            excludeApps: excludes)
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

    /// Validate `#RRGGBB` (case-insensitive). Returns the canonical
    /// `#rrggbb` lowercase form, or `nil` on a malformed input.
    private static func sanitiseHex(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.hasPrefix("#"), t.count == 7,
              t.dropFirst().allSatisfy({ "0123456789abcdef".contains($0) })
        else { return nil }
        return t
    }
}

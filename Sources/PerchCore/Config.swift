// Typed view over the user's `~/.config/perch/config.toml`. The
// app only ever READS this file — no auto-generation, no runtime
// override persistence (same policy as stroke / facet).
//
// All accessors clamp out-of-range / unknown values to defaults
// instead of rejecting, so a typo in one key can't take down the
// whole daemon.
//
// As of PR #89 the config is grouped into sub-structs (`hotkey`,
// `overlay`, `effect`, `border`, `sound`, `behavior`, `regional`,
// `grid`, `chord`, `search`) matching the TOML section layout
// 1:1. The old flat layout grew to 40+ fields and kept tripping
// synthesized-init argument-order bugs on every addition. Each
// sub-struct is small enough to memorise; PerchConfig itself
// becomes a thin shell around the 11 nested structs.

import CoreGraphics
import Foundation

// MARK: - Sub-structs

/// `[hotkey]` — activation + cancel binding.
public struct HotkeyConfig: Sendable {
    /// Global hotkey that activates hint mode. Default `shift+space`.
    public let active: HotkeyCombo

    /// Key that dismisses an active overlay (single key, no
    /// modifiers). Default `"esc"`. Unknown names silently fall
    /// back to esc per typo-tolerance.
    public let cancel: String

    public init(active: HotkeyCombo, cancel: String) {
        self.active = active
        self.cancel = cancel
    }
}

/// `[labels]` — label alphabet + assignment priority.
public struct LabelsConfig: Sendable {
    public let alphabet: String
    /// When more elements exist than first-tier letters, assign the
    /// easiest keys to the elements closest to screen center.
    public let prioritiseCenter: Bool

    public init(alphabet: String, prioritiseCenter: Bool) {
        self.alphabet = alphabet
        self.prioritiseCenter = prioritiseCenter
    }
}

/// `[overlay]` — pill rendering knobs (theme + shape + font + a few
/// behaviour flags that affect the overlay specifically).
public struct OverlayConfig: Sendable {

    /// Theme palette — picks pill bg / accent / text / font kind
    /// in one knob. Default `.system` keeps the historical adaptive
    /// look (`NSColor.controlAccentColor` + dark pill tint).
    public let theme: Theme

    /// Accent override. When set to anything other than `"system"`,
    /// wins over the theme's accent — lets users mix a body theme
    /// with a personal highlight.
    public let accent: String

    /// Pill geometry: `.pill` / `.square` / `.circle` / `.underline`
    /// / `.tag`. Orthogonal to `theme`.
    public let pillShape: PillShape

    /// Pill label font size (pt). Clamped 8..32.
    public let fontSize: Double

    /// `true` to layer a frosted-glass `NSVisualEffectView` under
    /// the pills. `false` falls back to solid dark fill.
    public let blurEnabled: Bool

    /// Global motion kill-switch — when `false`, every effect
    /// driver collapses to its instant baseline.
    public let animEnabled: Bool

    /// Show AX-bound keyboard shortcut annotations on `--menu` pills.
    public let showShortcuts: Bool

    /// Hold-to-peek key. Empty = disabled.
    public let peekKey: String

    /// Show `⌃⌥⇧⌘` glyph in pill top-right corner while modifiers
    /// are held during hint mode.
    public let showModifierBadge: Bool

    public init(
        theme: Theme, accent: String, pillShape: PillShape,
        fontSize: Double, blurEnabled: Bool, animEnabled: Bool,
        showShortcuts: Bool, peekKey: String,
        showModifierBadge: Bool
    ) {
        self.theme = theme
        self.accent = accent
        self.pillShape = pillShape
        self.fontSize = fontSize
        self.blurEnabled = blurEnabled
        self.animEnabled = animEnabled
        self.showShortcuts = showShortcuts
        self.peekKey = peekKey
        self.showModifierBadge = showModifierBadge
    }
}

/// `[overlay.effect]` — animations for the four directions
/// (appear / match / unmatch / narrow) plus shared knobs.
public struct EffectConfig: Sendable {

    /// Entrance animation when the overlay appears.
    public let appear: AppearEffect

    /// Animation on the winning pill at resolve.
    public let match: MatchEffect

    /// Layered animation on the 200ms red flash for a missed key.
    public let unmatch: UnmatchEffect

    /// Per-pill exit animation when typed-prefix filters a pill out.
    public let narrow: MatchEffect

    /// Spatial magnitude scaler (subtle / normal / bold / wild).
    public let intensity: EffectIntensity

    /// Multiplier on every duration. Clamped 0.1..5.0.
    public let durationScale: Double

    public init(
        appear: AppearEffect, match: MatchEffect,
        unmatch: UnmatchEffect, narrow: MatchEffect,
        intensity: EffectIntensity, durationScale: Double
    ) {
        self.appear = appear
        self.match = match
        self.unmatch = unmatch
        self.narrow = narrow
        self.intensity = intensity
        self.durationScale = durationScale
    }
}

/// `[overlay.border]` — neon-border preset around each pill.
public struct BorderConfig: Sendable {
    public let effect: BorderEffect
    /// NSShadow bloom under the stroke.
    public let glow: Bool
    /// Line width in points. Clamped 0.5..30.
    public let width: Double
    /// Hue rotation period in seconds. Clamped 0..120 (0 locks color).
    public let cycleSeconds: Double

    public init(
        effect: BorderEffect, glow: Bool, width: Double,
        cycleSeconds: Double
    ) {
        self.effect = effect
        self.glow = glow
        self.width = width
        self.cycleSeconds = cycleSeconds
    }
}

/// `[overlay.sound]` — audio feedback. `match` / `unmatch` /
/// `activate` accept either a macOS system-sound name OR a file
/// path (tilde-expanded). Empty / `"none"` silences.
public struct SoundConfig: Sendable {
    public let match: String
    public let unmatch: String
    public let activate: String
    /// Master volume 0..1.
    public let volume: Double

    public init(
        match: String, unmatch: String, activate: String,
        volume: Double
    ) {
        self.match = match
        self.unmatch = unmatch
        self.activate = activate
        self.volume = volume
    }
}

/// `[behavior]` — AX walk + dispatch behaviour.
public struct BehaviorConfig: Sendable {
    public let autoClickOnUnique: Bool
    public let roles: [String]
    /// Role allow-list used inside an `AXWebArea` subtree. Falls
    /// back to `roles` when not explicitly configured.
    public let webRoles: [String]
    /// Bundle IDs to ignore (perch won't activate over these apps).
    public let excludeApps: [String]
    /// Min frame size for an element to be labeled. Clamped >= 0.
    public let minSize: Double
    /// Per-bundle-id overrides — only the keys explicitly set in
    /// the section apply; missing keys fall through to the global.
    public let perApp: [String: BehaviorOverrides]

    public init(
        autoClickOnUnique: Bool, roles: [String],
        webRoles: [String], excludeApps: [String],
        minSize: Double, perApp: [String: BehaviorOverrides]
    ) {
        self.autoClickOnUnique = autoClickOnUnique
        self.roles = roles
        self.webRoles = webRoles
        self.excludeApps = excludeApps
        self.minSize = minSize
        self.perApp = perApp
    }

    /// Effective `roles` allow-list for `bundleID`.
    public func effectiveRoles(for bundleID: String?) -> [String] {
        guard let bid = bundleID,
              let o = perApp[bid],
              let r = o.roles else { return roles }
        return r
    }

    /// Effective `min-size` floor for `bundleID`.
    public func effectiveMinSize(for bundleID: String?) -> Double {
        guard let bid = bundleID,
              let o = perApp[bid],
              let m = o.minSize else { return minSize }
        return m
    }

    /// Effective `auto-click-on-unique` for `bundleID`.
    public func effectiveAutoClickOnUnique(for bundleID: String?) -> Bool {
        guard let bid = bundleID,
              let o = perApp[bid],
              let b = o.autoClickOnUnique else { return autoClickOnUnique }
        return b
    }
}

/// `[regional]` — frame floor for regional-mode container labeling.
public struct RegionalConfig: Sendable {
    public let minWidth: Double
    public let minHeight: Double

    public init(minWidth: Double, minHeight: Double) {
        self.minWidth = minWidth
        self.minHeight = minHeight
    }
}

/// `[grid]` — single-pass + recursive grid density + nested grid.
public struct GridConfig: Sendable {
    public let cols: Int
    public let rows: Int
    /// `--rgrid` cells per axis at each drill level. Smaller than
    /// `cols`/`rows` so the recursive case picks with single-letter
    /// labels per level.
    public let recursiveCols: Int
    public let recursiveRows: Int
    /// `,g` chord falls back to AXPress for elements smaller than
    /// this floor (subdividing a button with another grid is
    /// meaningless).
    public let nestMinSize: Double
    /// Max recursive drill depth. Clamped 1..10.
    public let maxDepth: Int

    public init(
        cols: Int, rows: Int, recursiveCols: Int, recursiveRows: Int,
        nestMinSize: Double, maxDepth: Int
    ) {
        self.cols = cols
        self.rows = rows
        self.recursiveCols = recursiveCols
        self.recursiveRows = recursiveRows
        self.nestMinSize = nestMinSize
        self.maxDepth = maxDepth
    }
}

/// `[chord]` — chord-suffix action mode (#57).
public struct ChordConfig: Sendable {
    /// Leader char (single lowercase). Empty disables chord mode.
    public let leader: String
    public let timeoutMs: Double

    public init(leader: String, timeoutMs: Double) {
        self.leader = leader
        self.timeoutMs = timeoutMs
    }
}

/// `[search.synonyms]` — fuzzy-match expansion table for search /
/// menu / windows / emoji.
public struct SearchConfig: Sendable {
    public let synonyms: [String: [String]]

    public init(synonyms: [String: [String]]) {
        self.synonyms = synonyms
    }
}

/// Per-bundle-id partial override of the `[behavior]` section. Every
/// field is optional: only the keys the user explicitly set in
/// `[behavior."com.foo.bar"]` are non-nil; missing keys fall through
/// to the global `[behavior]` value at resolve time.
public struct BehaviorOverrides: Sendable, Equatable {
    public let roles: [String]?
    public let minSize: Double?
    public let autoClickOnUnique: Bool?

    public init(
        roles: [String]? = nil,
        minSize: Double? = nil,
        autoClickOnUnique: Bool? = nil
    ) {
        self.roles = roles
        self.minSize = minSize
        self.autoClickOnUnique = autoClickOnUnique
    }
}

// MARK: - PerchConfig

public struct PerchConfig: Sendable {

    public let hotkey: HotkeyConfig
    public let labels: LabelsConfig
    public let overlay: OverlayConfig
    public let effect: EffectConfig
    public let border: BorderConfig
    public let sound: SoundConfig
    public let behavior: BehaviorConfig
    public let regional: RegionalConfig
    public let grid: GridConfig
    public let chord: ChordConfig
    public let search: SearchConfig

    public init(
        hotkey: HotkeyConfig, labels: LabelsConfig,
        overlay: OverlayConfig, effect: EffectConfig,
        border: BorderConfig, sound: SoundConfig,
        behavior: BehaviorConfig, regional: RegionalConfig,
        grid: GridConfig, chord: ChordConfig, search: SearchConfig
    ) {
        self.hotkey = hotkey
        self.labels = labels
        self.overlay = overlay
        self.effect = effect
        self.border = border
        self.sound = sound
        self.behavior = behavior
        self.regional = regional
        self.grid = grid
        self.chord = chord
        self.search = search
    }

    // MARK: - Constants

    /// Resolved path of the user's config file.
    public static let path: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/perch/config.toml"
    }()

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
        hotkey: HotkeyConfig(
            active: defaultHotkey, cancel: defaultCancelKey),
        labels: LabelsConfig(
            alphabet: defaultAlphabet, prioritiseCenter: true),
        overlay: OverlayConfig(
            theme: .system, accent: "system", pillShape: .pill,
            fontSize: 15, blurEnabled: true, animEnabled: true,
            showShortcuts: true, peekKey: "space",
            showModifierBadge: false),
        effect: EffectConfig(
            appear: .pop, match: .none, unmatch: .none,
            narrow: .none, intensity: .normal, durationScale: 1.0),
        border: BorderConfig(
            effect: .off, glow: true, width: 1.5, cycleSeconds: 3.0),
        sound: SoundConfig(
            match: "", unmatch: "", activate: "", volume: 0.5),
        behavior: BehaviorConfig(
            autoClickOnUnique: true, roles: defaultRoles,
            webRoles: defaultRoles, excludeApps: [], minSize: 6,
            perApp: [:]),
        regional: RegionalConfig(minWidth: 200, minHeight: 100),
        grid: GridConfig(
            cols: 12, rows: 8, recursiveCols: 3, recursiveRows: 3,
            nestMinSize: 100, maxDepth: 3),
        chord: ChordConfig(leader: "", timeoutMs: 600),
        search: SearchConfig(synonyms: [:]))

    // MARK: - Load / parse

    /// Read the config file from disk and return a fully-resolved
    /// `PerchConfig`. Missing file → all defaults.
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

        return PerchConfig(
            hotkey: parseHotkey(doc),
            labels: parseLabels(doc),
            overlay: parseOverlay(doc),
            effect: parseEffect(doc),
            border: parseBorder(doc),
            sound: parseSound(doc),
            behavior: parseBehavior(doc),
            regional: parseRegional(doc),
            grid: parseGrid(doc),
            chord: parseChord(doc),
            search: parseSearch(doc))
    }

    // MARK: - Section parsers

    private static func parseHotkey(_ doc: TOML.Document) -> HotkeyConfig {
        let hk = doc["hotkey"]?["active"]?.asString
            .flatMap(HotkeyCombo.parse) ?? defaultHotkey
        let cancel = (doc["hotkey"]?["cancel"]?.asString)
            .flatMap { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? defaultCancelKey
        return HotkeyConfig(active: hk, cancel: cancel)
    }

    private static func parseLabels(_ doc: TOML.Document) -> LabelsConfig {
        let alphabet = (doc["labels"]?["alphabet"]?.asString)
            .flatMap { sanitiseAlphabet($0) } ?? defaultAlphabet
        let priority = doc["labels"]?["prioritise-center"]?.asBool ?? true
        return LabelsConfig(
            alphabet: alphabet, prioritiseCenter: priority)
    }

    private static func parseOverlay(_ doc: TOML.Document) -> OverlayConfig {
        let accent = (doc["overlay"]?["accent"]?.asString)
            .flatMap(sanitiseAccent) ?? "system"
        // .random resolves once at parse so the chosen palette stays
        // stable for the daemon's life (each --reload rolls fresh).
        let theme = (doc["overlay"]?["theme"]?.asString)
            .flatMap(Theme.parse)?.resolvingRandom() ?? .system
        let shape = (doc["overlay"]?["pill-shape"]?.asString)
            .flatMap(PillShape.parse) ?? .pill
        let size = (doc["overlay"]?["font-size"]?.asDouble).map {
            min(max($0, 8), 32)
        } ?? 15
        let blur = doc["overlay"]?["blur-enabled"]?.asBool ?? true
        let anim = doc["overlay"]?["anim-enabled"]?.asBool ?? true
        let showShortcuts = doc["overlay"]?["show-shortcuts"]?.asBool ?? true
        let peekKey = (doc["overlay"]?["peek-key"]?.asString)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            ?? "space"
        let showBadge = doc["overlay"]?["show-modifier-badge"]?.asBool
            ?? false
        return OverlayConfig(
            theme: theme, accent: accent, pillShape: shape,
            fontSize: size, blurEnabled: blur, animEnabled: anim,
            showShortcuts: showShortcuts, peekKey: peekKey,
            showModifierBadge: showBadge)
    }

    private static func parseEffect(_ doc: TOML.Document) -> EffectConfig {
        let eff = doc["overlay.effect"]
        let appear = (eff?["appear"]?.asString)
            .flatMap(AppearEffect.parse)?.resolvingRandom() ?? .pop
        let match = (eff?["match"]?.asString)
            .flatMap(MatchEffect.parse) ?? .none
        let unmatch = (eff?["unmatch"]?.asString)
            .flatMap(UnmatchEffect.parse) ?? .none
        let narrow = (eff?["narrow"]?.asString)
            .flatMap(MatchEffect.parse) ?? .none
        let intensity = (eff?["intensity"]?.asString)
            .flatMap(EffectIntensity.parse) ?? .normal
        let durScale: Double = {
            guard let raw = eff?["duration-scale"]?.asDouble
            else { return 1.0 }
            return raw >= 0.1 && raw <= 5.0 ? raw : 1.0
        }()
        return EffectConfig(
            appear: appear, match: match, unmatch: unmatch,
            narrow: narrow, intensity: intensity,
            durationScale: durScale)
    }

    private static func parseBorder(_ doc: TOML.Document) -> BorderConfig {
        let b = doc["overlay.border"]
        let effect = (b?["effect"]?.asString)
            .flatMap(BorderEffect.parse)?.resolvingRandom() ?? .off
        let glow = b?["glow"]?.asBool ?? true
        let width: Double = {
            guard let raw = b?["width"]?.asDouble else { return 1.5 }
            return raw >= 0.5 && raw <= 30 ? raw : 1.5
        }()
        let cycle: Double = {
            guard let raw = b?["cycle-seconds"]?.asDouble
            else { return 3.0 }
            return raw >= 0 && raw <= 120 ? raw : 3.0
        }()
        return BorderConfig(
            effect: effect, glow: glow, width: width,
            cycleSeconds: cycle)
    }

    private static func parseSound(_ doc: TOML.Document) -> SoundConfig {
        let s = doc["overlay.sound"]
        let match = s?["match"]?.asString ?? ""
        let unmatch = s?["unmatch"]?.asString ?? ""
        let activate = s?["activate"]?.asString ?? ""
        let volume: Double = {
            guard let raw = s?["volume"]?.asDouble else { return 0.5 }
            return max(0, min(1, raw))
        }()
        return SoundConfig(
            match: match, unmatch: unmatch, activate: activate,
            volume: volume)
    }

    private static func parseBehavior(_ doc: TOML.Document) -> BehaviorConfig {
        let autoClick = doc["behavior"]?["auto-click-on-unique"]?.asBool ?? true
        let roles = (doc["behavior"]?["roles"]?.asStringArray)
            .map { $0.filter { !$0.isEmpty } } ?? defaultRoles
        let excludes = doc["behavior"]?["exclude-apps"]?.asStringArray ?? []
        let minSize = (doc["behavior"]?["min-size"]?.asDouble).map {
            max(0, $0)
        } ?? 6
        let webRoles = (doc["behavior.web"]?["roles"]?.asStringArray)
            .map { $0.filter { !$0.isEmpty } } ?? roles

        // Per-app overrides — `[behavior."<bundle-id>"]` sections.
        // Same flat-key shape as `[behavior.web]`.
        var perApp: [String: BehaviorOverrides] = [:]
        for (raw, section) in doc {
            guard raw.hasPrefix("behavior.\""),
                  raw.hasSuffix("\""),
                  raw.count > "behavior.\"\"".count
            else { continue }
            let bid = String(raw.dropFirst("behavior.\"".count).dropLast())
            guard !bid.isEmpty else { continue }
            let r = section["roles"]?.asStringArray
                .map { $0.filter { !$0.isEmpty } }
            let m = section["min-size"]?.asDouble.map { max(0, $0) }
            let a = section["auto-click-on-unique"]?.asBool
            if r == nil, m == nil, a == nil { continue }
            perApp[bid] = BehaviorOverrides(
                roles: r, minSize: m, autoClickOnUnique: a)
        }

        return BehaviorConfig(
            autoClickOnUnique: autoClick, roles: roles,
            webRoles: webRoles, excludeApps: excludes,
            minSize: minSize, perApp: perApp)
    }

    private static func parseRegional(_ doc: TOML.Document) -> RegionalConfig {
        let w = (doc["regional"]?["min-width"]?.asDouble)
            .map { max(0, $0) } ?? 200
        let h = (doc["regional"]?["min-height"]?.asDouble)
            .map { max(0, $0) } ?? 100
        return RegionalConfig(minWidth: w, minHeight: h)
    }

    private static func parseGrid(_ doc: TOML.Document) -> GridConfig {
        let cols: Int = {
            guard let raw = doc["grid"]?["cols"]?.asInt else { return 12 }
            return raw >= 2 && raw <= 32 ? raw : 12
        }()
        let rows: Int = {
            guard let raw = doc["grid"]?["rows"]?.asInt else { return 8 }
            return raw >= 2 && raw <= 32 ? raw : 8
        }()
        let rCols: Int = {
            guard let raw = doc["grid"]?["recursive-cols"]?.asInt
            else { return 3 }
            return raw >= 2 && raw <= 32 ? raw : 3
        }()
        let rRows: Int = {
            guard let raw = doc["grid"]?["recursive-rows"]?.asInt
            else { return 3 }
            return raw >= 2 && raw <= 32 ? raw : 3
        }()
        let maxDepth: Int = {
            guard let raw = doc["grid"]?["max-depth"]?.asInt
            else { return 3 }
            return raw >= 1 && raw <= 10 ? raw : 3
        }()
        let nestMin: Double = {
            guard let raw = doc["grid"]?["nest-min-size"]?.asDouble
            else { return 100 }
            return raw >= 1 && raw <= 1000 ? raw : 100
        }()
        return GridConfig(
            cols: cols, rows: rows, recursiveCols: rCols,
            recursiveRows: rRows, nestMinSize: nestMin,
            maxDepth: maxDepth)
    }

    private static func parseChord(_ doc: TOML.Document) -> ChordConfig {
        let leader: String = {
            guard let raw = doc["chord"]?["leader"]?.asString else {
                return ""
            }
            let trimmed = raw
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            return String(trimmed.prefix(1))
        }()
        let timeoutMs = (doc["chord"]?["timeout-ms"]?.asDouble)
            .map { max(0, min($0, 5000)) } ?? 600
        return ChordConfig(leader: leader, timeoutMs: timeoutMs)
    }

    private static func parseSearch(_ doc: TOML.Document) -> SearchConfig {
        var synonyms: [String: [String]] = [:]
        if let section = doc["search.synonyms"] {
            for (rawKey, value) in section {
                let key = rawKey.lowercased()
                guard !key.isEmpty,
                      let arr = value.asStringArray else { continue }
                let cleaned = arr
                    .map { $0.lowercased() }
                    .filter { !$0.isEmpty && $0 != key }
                if cleaned.isEmpty { continue }
                synonyms[key] = cleaned
            }
        }
        return SearchConfig(synonyms: synonyms)
    }

    // MARK: - Sanitisers

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

    /// Accept "system" or a `#rrggbb` literal. Returns canonical
    /// lowercase, or `nil` on malformed input so the caller can clamp.
    private static func sanitiseAccent(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "system" || t == "accent" { return "system" }
        guard t.hasPrefix("#"), t.count == 7,
              t.dropFirst().allSatisfy({ "0123456789abcdef".contains($0) })
        else { return nil }
        return t
    }
}

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

    /// User-defined palettes from `[overlay.themes.<name>]` sections.
    /// Keyed by the section name (e.g. `"my-theme"`). When
    /// `[overlay].theme = "<name>"` matches a key here, the custom
    /// palette wins over the built-in catalog.
    ///
    /// Example:
    /// ```toml
    /// [overlay.themes.my-theme]
    /// pill-bg = "#1a1a1a"
    /// accent  = "#ff8800"
    /// text    = "#ffffff"
    /// font    = "rounded"
    ///
    /// [overlay]
    /// theme = "my-theme"
    /// ```
    public let customPalettes: [String: ThemePalette]

    /// When `[overlay].theme` matches a `[overlay.themes.<name>]`
    /// section, this is the name; otherwise nil. The resolver
    /// checks this before the built-in catalog.
    public let customThemeName: String?

    /// Hold-to-peek key. Empty = disabled.
    public let peekKey: String

    /// What the modifier-badge corner annotation shows when a
    /// modifier is held during hint mode. `.off` (default) skips
    /// the badge; `.glyph` shows `⌃⌥⇧⌘`; `.action` shows glyph +
    /// action verb (e.g. `⌘ Copy`).
    ///
    /// Older configs that used `show-modifier-badge = true` / `false`
    /// parse to `.glyph` / `.off` via `ModifierBadgeStyle.parse`.
    public let modifierBadge: ModifierBadgeStyle

    public init(
        theme: Theme, accent: String, pillShape: PillShape,
        fontSize: Double, blurEnabled: Bool, animEnabled: Bool,
        showShortcuts: Bool, peekKey: String,
        modifierBadge: ModifierBadgeStyle,
        customPalettes: [String: ThemePalette] = [:],
        customThemeName: String? = nil
    ) {
        self.theme = theme
        self.accent = accent
        self.pillShape = pillShape
        self.fontSize = fontSize
        self.blurEnabled = blurEnabled
        self.animEnabled = animEnabled
        self.showShortcuts = showShortcuts
        self.peekKey = peekKey
        self.modifierBadge = modifierBadge
        self.customPalettes = customPalettes
        self.customThemeName = customThemeName
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

/// Effect-channel resolvers — per-app `[behavior."<bundle>"]` keys
/// (e.g. `match-effect = "none"`) win over the global
/// `[overlay.effect]` defaults. Stored on `BehaviorConfig` so the
/// adapter only carries one config snapshot.
extension BehaviorConfig {
    public func effectiveAppearEffect(
        for bundleID: String?, fallback: AppearEffect
    ) -> AppearEffect {
        guard let bid = bundleID,
              let e = perApp[bid]?.appearEffect else { return fallback }
        return e
    }

    public func effectiveMatchEffect(
        for bundleID: String?, fallback: MatchEffect
    ) -> MatchEffect {
        guard let bid = bundleID,
              let e = perApp[bid]?.matchEffect else { return fallback }
        return e
    }

    public func effectiveUnmatchEffect(
        for bundleID: String?, fallback: UnmatchEffect
    ) -> UnmatchEffect {
        guard let bid = bundleID,
              let e = perApp[bid]?.unmatchEffect else { return fallback }
        return e
    }

    public func effectiveNarrowEffect(
        for bundleID: String?, fallback: MatchEffect
    ) -> MatchEffect {
        guard let bid = bundleID,
              let e = perApp[bid]?.narrowEffect else { return fallback }
        return e
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
/// to the global value at resolve time.
///
/// Includes effect-kind overrides (`appear-effect` / `match-effect` /
/// `unmatch-effect` / `narrow-effect`) so users can tame the
/// "wild + fireworks" preset per app — e.g. silence all effects
/// inside Figma but keep them globally.
public struct BehaviorOverrides: Sendable, Equatable {
    public let roles: [String]?
    public let minSize: Double?
    public let autoClickOnUnique: Bool?
    public let appearEffect: AppearEffect?
    public let matchEffect: MatchEffect?
    public let unmatchEffect: UnmatchEffect?
    public let narrowEffect: MatchEffect?

    public init(
        roles: [String]? = nil,
        minSize: Double? = nil,
        autoClickOnUnique: Bool? = nil,
        appearEffect: AppearEffect? = nil,
        matchEffect: MatchEffect? = nil,
        unmatchEffect: UnmatchEffect? = nil,
        narrowEffect: MatchEffect? = nil
    ) {
        self.roles = roles
        self.minSize = minSize
        self.autoClickOnUnique = autoClickOnUnique
        self.appearEffect = appearEffect
        self.matchEffect = matchEffect
        self.unmatchEffect = unmatchEffect
        self.narrowEffect = narrowEffect
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

    /// Return a copy of this config with `overlay.theme` (and
    /// optionally `overlay.customThemeName`) replaced. Used by the
    /// `--theme=<name>` session override so the Controller doesn't
    /// have to hand-construct a full PerchConfig with one field
    /// changed. Every other field carries over unchanged.
    public func withTheme(
        _ theme: Theme, customName: String?
    ) -> PerchConfig {
        let newOverlay = OverlayConfig(
            theme: theme,
            accent: overlay.accent,
            pillShape: overlay.pillShape,
            fontSize: overlay.fontSize,
            blurEnabled: overlay.blurEnabled,
            animEnabled: overlay.animEnabled,
            showShortcuts: overlay.showShortcuts,
            peekKey: overlay.peekKey,
            modifierBadge: overlay.modifierBadge,
            customPalettes: overlay.customPalettes,
            customThemeName: customName)
        return PerchConfig(
            hotkey: hotkey, labels: labels, overlay: newOverlay,
            effect: effect, border: border, sound: sound,
            behavior: behavior, regional: regional, grid: grid,
            chord: chord, search: search)
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
            modifierBadge: .off),
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

        // [overlay.themes.<name>] user-defined palettes — same flat-
        // key shape as [behavior."<bundle>"]. Each section is a
        // (pill-bg, accent, text, miss, pill-bg-alpha, font) tuple
        // matching ThemePalette.
        let customPalettes = parseCustomPalettes(doc)

        // Resolve [overlay].theme: raw string first, then check
        // custom palettes, then the built-in enum. `.random`
        // resolves to a concrete built-in here.
        let rawTheme = (doc["overlay"]?["theme"]?.asString)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            ?? ""
        let theme: Theme
        let customThemeName: String?
        if !rawTheme.isEmpty, customPalettes[rawTheme] != nil {
            // Custom palette wins — store the name, leave Theme on
            // .system so the built-in resolver can't accidentally
            // hide the custom palette later.
            customThemeName = rawTheme
            theme = .system
        } else {
            customThemeName = nil
            theme = Theme.parse(rawTheme)?.resolvingRandom() ?? .system
        }
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
        // show-modifier-badge is a string enum: "off" / "glyph" /
        // "action". The PR #92 transitional bool support ("true" →
        // .glyph) is gone — config edited after PR #96 must use the
        // string form. The string parser still accepts "true" /
        // "false" / "yes" / "no" (case-insensitive) for the people
        // who carry over old bool literals, but a raw TOML bool
        // (no quotes) now silently lands on .off + a warning.
        let badge: ModifierBadgeStyle
        if let s = doc["overlay"]?["show-modifier-badge"]?.asString {
            badge = ModifierBadgeStyle.parse(s) ?? .off
        } else if doc["overlay"]?["show-modifier-badge"]?.asBool != nil {
            Log.line("config: show-modifier-badge — bare bool no longer "
                     + "supported; use \"off\" / \"glyph\" / \"action\". "
                     + "Falling back to \"off\".")
            badge = .off
        } else {
            badge = .off
        }
        return OverlayConfig(
            theme: theme, accent: accent, pillShape: shape,
            fontSize: size, blurEnabled: blur, animEnabled: anim,
            showShortcuts: showShortcuts, peekKey: peekKey,
            modifierBadge: badge,
            customPalettes: customPalettes,
            customThemeName: customThemeName)
    }

    /// Walk every `[overlay.themes.<name>]` section and assemble a
    /// `[name: ThemePalette]` dict. The TOML parser lands these as
    /// flat keys (`"overlay.themes.my-theme"`), same as
    /// `[behavior."<bundle>"]`. Unknown / malformed values fall
    /// back to system defaults per typo-tolerance — a typo never
    /// kills the palette.
    private static func parseCustomPalettes(
        _ doc: TOML.Document
    ) -> [String: ThemePalette] {
        var out: [String: ThemePalette] = [:]
        // Plural `themes` (not `theme`) because `[overlay].theme` is
        // a scalar (the selector); strict TOML 1.0 parsers reject
        // `[overlay.themes.<name>]` since `theme` would have to be
        // both a string AND a table parent. `themes` is a separate
        // key path with no such conflict.
        let prefix = "overlay.themes."
        // Warn anyone still using the pre-PR #95 singular form so
        // they don't silently lose their custom palette to the
        // typo-tolerance fallthrough.
        let deprecatedPrefix = "overlay.theme."
        for rawKey in doc.keys
            where rawKey.hasPrefix(deprecatedPrefix)
            && !rawKey.hasPrefix(prefix) {
            let name = String(rawKey.dropFirst(deprecatedPrefix.count))
            Log.line("config: [overlay.theme.\(name)] is deprecated — "
                     + "rename to [overlay.themes.\(name)] (plural). "
                     + "The singular form is silently ignored.")
        }
        // Names reserved by built-in themes / sentinels — silently
        // ignored if the user shadows them, since the catalog
        // would never see the custom palette.
        let reserved: Set<String> = Set(
            Theme.allCases.map { $0.rawValue })
        for (rawKey, section) in doc {
            guard rawKey.hasPrefix(prefix) else { continue }
            let name = String(rawKey.dropFirst(prefix.count))
                .lowercased()
            guard !name.isEmpty, !reserved.contains(name) else {
                Log.line("config: skipping custom theme \"\(name)\" "
                         + "— name shadows a built-in")
                continue
            }
            let pillBg = parseHexValue(section["pill-bg"]?.asString)
                ?? 0x000000
            let accent = parseHexValue(section["accent"]?.asString)
                ?? 0xFFFFFF
            let text = parseHexValue(section["text"]?.asString)
                ?? 0xFFFFFF
            let miss = parseHexValue(section["miss"]?.asString)
                ?? 0xEF4444
            let alpha: CGFloat = {
                guard let raw = section["pill-bg-alpha"]?.asDouble
                else { return 0.55 }
                return CGFloat(max(0, min(1, raw)))
            }()
            let font: ThemeFont = {
                guard let raw = section["font"]?.asString
                else { return .mono }
                switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
                case "mono":    return .mono
                case "rounded": return .rounded
                case "system":  return .system
                default:        return .mono
                }
            }()
            out[name] = ThemePalette(
                pillBgHex: pillBg, accentHex: accent,
                textHex: text, missHex: miss,
                pillBgAlpha: alpha, font: font)
        }
        return out
    }

    /// `"#rrggbb"` → `0xRRGGBB`. Trims + lowercases + validates 6
    /// hex digits. Returns nil on malformed input so the caller can
    /// fall back to a default.
    private static func parseHexValue(_ s: String?) -> UInt32? {
        guard var t = s?.trimmingCharacters(in: .whitespaces)
            .lowercased() else { return nil }
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6,
              t.allSatisfy({ "0123456789abcdef".contains($0) })
        else { return nil }
        return UInt32(t, radix: 16)
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
        // Particle kinds in the narrow context fall through to .fade
        // at runtime (`GhostDriver.spawn`) — warn the user once at
        // parse-time so they know the dispatch differs from what
        // they wrote, instead of debugging a missing burst later.
        if narrow == .fireworks || narrow == .confetti {
            Log.line("config: [overlay.effect].narrow = "
                     + "\"\(narrow.rawValue)\" downgrades to "
                     + "\"fade\" at runtime — per-pill particle "
                     + "bursts on a dense hint set would emit "
                     + "hundreds of simultaneous particles.")
        }
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
            let appear = section["appear-effect"]?.asString
                .flatMap(AppearEffect.parse)
            let match = section["match-effect"]?.asString
                .flatMap(MatchEffect.parse)
            let unmatch = section["unmatch-effect"]?.asString
                .flatMap(UnmatchEffect.parse)
            let narrow = section["narrow-effect"]?.asString
                .flatMap(MatchEffect.parse)
            if r == nil, m == nil, a == nil,
               appear == nil, match == nil,
               unmatch == nil, narrow == nil { continue }
            perApp[bid] = BehaviorOverrides(
                roles: r, minSize: m, autoClickOnUnique: a,
                appearEffect: appear, matchEffect: match,
                unmatchEffect: unmatch, narrowEffect: narrow)
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

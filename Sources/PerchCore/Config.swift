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
import Palette
import Toml

/// A flat TOML document: literal section-header → key → value. perch
/// reads its config through sill's `Toml.parseFlat`, whose
/// `Document.tables` has exactly this shape — lenient (a typo drops one
/// line, not the daemon) and keyed by the verbatim header text so
/// `[behavior."<bundle>"]` and `[overlay.themes.<name>]` stay literal.
/// The four hand-rolled family parsers folded into sill's `Toml` module
/// in atelier Phase 1.6; this alias keeps the section-parser signatures
/// readable. Values are read via `Toml.Value`'s accessors (`asString`,
/// `asDouble`, `asStringArray`, …).
private typealias TOMLDoc = [String: [String: Toml.Value]]

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

    /// Canonical theme name (sill `canonicalThemeNames`, validated +
    /// `random`-resolved at parse). Picks pill bg / accent / text /
    /// font in one knob. Default `"system"` keeps the historical
    /// adaptive look (`NSColor.controlAccentColor` + dark pill tint).
    /// When a `[overlay.themes.<name>]` custom palette is selected this
    /// stays `"system"` and `customThemeName` carries the name.
    public let theme: String

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

    /// User-defined palettes from `[overlay.themes.<name>]` sections,
    /// each a full sill `ThemeSpec` (pill-bg → `bg`, accent, text,
    /// miss → `error`, pill-bg-alpha → `bgAlpha`, font). Keyed by the
    /// section name (e.g. `"my-theme"`). When `[overlay].theme =
    /// "<name>"` matches a key here, the custom palette wins over the
    /// built-in catalog.
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
    public let customPalettes: [String: ThemeSpec]

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
        theme: String, accent: String, pillShape: PillShape,
        fontSize: Double, blurEnabled: Bool, animEnabled: Bool,
        showShortcuts: Bool, peekKey: String,
        modifierBadge: ModifierBadgeStyle,
        customPalettes: [String: ThemeSpec] = [:],
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
/// path (tilde-expanded). Empty (`""`) silences.
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
/// (e.g. `match-effect = "off"`) win over the global
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
        _ theme: String, customName: String?
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
            theme: "system", accent: "system", pillShape: .pill,
            fontSize: 15, blurEnabled: true, animEnabled: true,
            showShortcuts: true, peekKey: "space",
            modifierBadge: .off),
        effect: EffectConfig(
            appear: .pop, match: .off, unmatch: .off,
            narrow: .off, intensity: .normal, durationScale: 1.0),
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
    ///
    /// The UNIFORM scalar sections (`[labels]`/`[overlay]` scalars/
    /// `[overlay.effect]`/`[overlay.border]`/`[overlay.sound]`/`[exclude]`/
    /// `[regional]`/`[grid]` + the scalar `[hotkey]`/`[chord]` keys) are
    /// driven by the SINGLE declarative `configSpec` (which ALSO emits the
    /// JSON Schema — see `PerchConfig+Spec.swift`), decoded into a mutable
    /// `Staged` seeded with the built-in defaults. The NON-uniform bits stay
    /// bespoke below (custom palettes, per-app/bundle-id overrides, the theme
    /// custom-palette interplay, the deprecation log, synonyms, and the
    /// grammar-parsed `hotkey.active` / `labels.alphabet` / `chord.leader`).
    /// The spec drives both decode and schema, so the two can never drift.
    public static func parse(_ source: String) -> PerchConfig {
        // sill's flat skin — keyed by literal header text, lenient.
        // perch's old single-line-only parser dropped the multi-line
        // `[behavior].roles` array (silently falling back to
        // `defaultRoles`); `Toml.parseFlat` accumulates it correctly.
        let doc = Toml.parseFlat(source).tables

        // Drive the uniform scalar sections off the one declarative spec.
        var s = Staged()
        configSpec.decode(doc, into: &s)

        return PerchConfig(
            hotkey: assembleHotkey(doc, s),
            labels: assembleLabels(doc, s),
            overlay: assembleOverlay(doc, s),
            effect: assembleEffect(s),
            border: BorderConfig(
                effect: s.borderEffect, glow: s.borderGlow,
                width: s.borderWidth, cycleSeconds: s.borderCycleSeconds),
            sound: SoundConfig(
                match: s.soundMatch, unmatch: s.soundUnmatch,
                activate: s.soundActivate, volume: s.volume),
            behavior: assembleBehavior(doc, s),
            regional: RegionalConfig(
                minWidth: s.regMinWidth, minHeight: s.regMinHeight),
            grid: GridConfig(
                cols: s.gridCols, rows: s.gridRows,
                recursiveCols: s.recursiveCols, recursiveRows: s.recursiveRows,
                nestMinSize: s.nestMinSize, maxDepth: s.maxDepth),
            chord: assembleChord(doc, s),
            search: parseSearch(doc))
    }

    // MARK: - Section assembly (spec-driven `Staged` + bespoke fields)

    /// `[hotkey]` — `cancel` came from the spec; `active` is bespoke
    /// (HotkeyCombo modifier+key grammar — not a uniform scalar).
    private static func assembleHotkey(
        _ doc: TOMLDoc, _ s: Staged
    ) -> HotkeyConfig {
        let hk = doc["hotkey"]?["active"]?.asString
            .flatMap(HotkeyCombo.parse) ?? defaultHotkey
        return HotkeyConfig(active: hk, cancel: s.cancel)
    }

    /// `[labels]` — `prioritise-center` came from the spec; `alphabet`
    /// is bespoke (`sanitiseAlphabet` de-dup/clean, not a plain scalar).
    private static func assembleLabels(
        _ doc: TOMLDoc, _ s: Staged
    ) -> LabelsConfig {
        let alphabet = (doc["labels"]?["alphabet"]?.asString)
            .flatMap { sanitiseAlphabet($0) } ?? defaultAlphabet
        return LabelsConfig(
            alphabet: alphabet, prioritiseCenter: s.prioritiseCenter)
    }

    /// `[overlay]` — `accent`/`pill-shape`/`font-size`/`blur`/`anim`/
    /// `shortcut-badge`/`peek-key` came from the spec; `theme` (custom-
    /// palette interplay + `random`), `show-modifier-badge` (bool back-
    /// compat + deprecation log), and the `[overlay.themes.<name>]`
    /// custom palettes are bespoke.
    private static func assembleOverlay(
        _ doc: TOMLDoc, _ s: Staged
    ) -> OverlayConfig {
        // [overlay.themes.<name>] user-defined palettes — same flat-
        // key shape as [behavior."<bundle>"]. Each section is a
        // (pill-bg, accent, text, miss, pill-bg-alpha, font) tuple
        // resolved into a sill ThemeSpec.
        let customPalettes = parseCustomPalettes(doc)

        // Resolve [overlay].theme: raw string first, then check custom
        // palettes, then sill's canonical name set. `random` resolves
        // to a concrete name HERE (session-stable); an unknown name
        // clamps silently to "system" per the TOML clamp-don't-reject
        // rule (the loud-rejection path is the `--theme=` CLI override
        // in Controller).
        let rawTheme = (doc["overlay"]?["theme"]?.asString)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            ?? ""
        let theme: String
        let customThemeName: String?
        if !rawTheme.isEmpty, customPalettes[rawTheme] != nil {
            // Custom palette wins — store the name, leave theme on
            // "system" so the built-in resolver can't accidentally
            // hide the custom palette later.
            customThemeName = rawTheme
            theme = "system"
        } else {
            customThemeName = nil
            theme = perchCanonicalThemeName(rawTheme) ?? "system"
        }
        // show-modifier-badge is a string enum: "off" / "glyph" /
        // "action". The PR #92 transitional bool support ("true" →
        // .glyph) is gone — config edited after PR #96 must use the
        // string form. The string parser still accepts "true" /
        // "false" / "yes" / "no" (case-insensitive) for the people
        // who carry over old bool literals, but a raw TOML bool
        // (no quotes) now silently lands on .off + a warning.
        let badge: ModifierBadgeStyle
        if let str = doc["overlay"]?["show-modifier-badge"]?.asString {
            badge = ModifierBadgeStyle.parse(str) ?? .off
        } else if doc["overlay"]?["show-modifier-badge"]?.asBool != nil {
            Log.line("config: show-modifier-badge — bare bool no longer "
                     + "supported; use \"off\" / \"glyph\" / \"action\". "
                     + "Falling back to \"off\".")
            badge = .off
        } else {
            badge = .off
        }
        return OverlayConfig(
            theme: theme, accent: s.accent, pillShape: s.pillShape,
            fontSize: s.fontSize, blurEnabled: s.blurEnabled,
            animEnabled: s.animEnabled,
            showShortcuts: s.showShortcuts, peekKey: s.peekKey,
            modifierBadge: badge,
            customPalettes: customPalettes,
            customThemeName: customThemeName)
    }

    /// `[overlay.effect]` — every field came from the spec. The only
    /// non-decode bit is the parse-time warning when `narrow` is a
    /// particle kind (it downgrades to `.fade` at runtime); re-derived
    /// here from the resolved value so the user still sees it.
    private static func assembleEffect(_ s: Staged) -> EffectConfig {
        // Particle kinds in the narrow context fall through to .fade
        // at runtime (`GhostDriver.spawn`) — warn the user once at
        // parse-time so they know the dispatch differs from what
        // they wrote, instead of debugging a missing burst later.
        if s.narrow == .fireworks || s.narrow == .confetti {
            Log.line("config: [overlay.effect].narrow = "
                     + "\"\(s.narrow.rawValue)\" downgrades to "
                     + "\"fade\" at runtime — per-pill particle "
                     + "bursts on a dense hint set would emit "
                     + "hundreds of simultaneous particles.")
        }
        return EffectConfig(
            appear: s.appear, match: s.match, unmatch: s.unmatch,
            narrow: s.narrow, intensity: s.intensity,
            durationScale: s.durationScale)
    }

    /// `[behavior]` — `auto-click-on-unique`/`min-size` came from the
    /// spec, and `excludeApps` from the spec's `[exclude].apps`. The
    /// `roles` / web-`roles` arrays (empty-entry filtering + the
    /// web→global fallback) and the per-bundle-id `[behavior."<id>"]`
    /// overrides are bespoke.
    private static func assembleBehavior(
        _ doc: TOMLDoc, _ s: Staged
    ) -> BehaviorConfig {
        let roles = (doc["behavior"]?["roles"]?.asStringArray)
            .map { $0.filter { !$0.isEmpty } } ?? defaultRoles
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
            autoClickOnUnique: s.autoClickOnUnique, roles: roles,
            webRoles: webRoles, excludeApps: s.excludeApps,
            minSize: s.minSize, perApp: perApp)
    }

    /// `[chord]` — `timeout-ms` came from the spec; `leader` is bespoke
    /// (first-char-only after trim+lowercase, not a plain scalar).
    private static func assembleChord(
        _ doc: TOMLDoc, _ s: Staged
    ) -> ChordConfig {
        let leader: String = {
            guard let raw = doc["chord"]?["leader"]?.asString else {
                return ""
            }
            let trimmed = raw
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            return String(trimmed.prefix(1))
        }()
        return ChordConfig(leader: leader, timeoutMs: s.timeoutMs)
    }

    /// Walk every `[overlay.themes.<name>]` section and assemble a
    /// `[name: ThemeSpec]` dict (sill's pure spec). The TOML parser
    /// lands these as flat keys (`"overlay.themes.my-theme"`), same as
    /// `[behavior."<bundle>"]`. Unknown / malformed values fall
    /// back to system defaults per typo-tolerance — a typo never
    /// kills the palette.
    private static func parseCustomPalettes(
        _ doc: TOMLDoc
    ) -> [String: ThemeSpec] {
        var out: [String: ThemeSpec] = [:]
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
        let reserved: Set<String> = Set(canonicalThemeNames)
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
            let alpha: Double = {
                guard let raw = section["pill-bg-alpha"]?.asDouble
                else { return 0.55 }
                return max(0, min(1, raw))
            }()
            let font: FontKind = {
                guard let raw = section["font"]?.asString
                else { return .mono }
                switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
                case "mono":    return .mono
                case "rounded": return .rounded
                case "system":  return .system
                case "menu":    return .menu
                default:        return .mono
                }
            }()
            // Map perch's custom-palette keys onto a sill ThemeSpec:
            // pill-bg → background, miss → error, pill-bg-alpha →
            // backgroundAlpha. perch doesn't read
            // muted/secondary/border/hover/selection for pills, so muted
            // is a placeholder (= foreground) and the rest stay nil.
            out[name] = ThemeSpec(
                background: HexColor(pillBg),
                foreground: HexColor(text),
                muted: HexColor(text),
                primary: HexColor(accent),
                font: font,
                error: HexColor(miss),
                backgroundAlpha: alpha)
        }
        return out
    }

    /// Colour token → `0xRRGGBB` via sill's shared grammar
    /// (`parseColorToken`): named colours, `#rgb`, `#rrggbb`,
    /// `#rrggbbaa` (alpha ignored here — pill translucency is its own
    /// knob). Returns nil on malformed input so the caller can fall
    /// back to a default.
    private static func parseHexValue(_ s: String?) -> UInt32? {
        guard let s else { return nil }
        return parseColorToken(s)?.rgb
    }

    private static func parseSearch(_ doc: TOMLDoc) -> SearchConfig {
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

    // Note: `sanitiseAlphabet` / `sanitiseAccent` now live in
    // `PerchConfig+Spec.swift` (non-private static) so BOTH the spec's
    // `apply` closures and this file's bespoke assembly share one copy.
}

// Typed view over the user's `~/.config/perch/config.toml`. The
// app only ever READS this file — no auto-generation, no runtime
// override persistence (same policy as stroke / facet).
//
// All accessors clamp out-of-range / unknown values to defaults
// instead of rejecting, so a typo in one key can't take down the
// whole daemon.

import CoreGraphics
import Foundation

/// Per-bundle-id partial override of the `[behavior]` section. Every
/// field is optional: only the keys the user explicitly set in
/// `[behavior."com.foo.bar"]` are non-nil; missing keys fall through
/// to the global `[behavior]` value at resolve time. This is the
/// "typo-tolerance preserves global defaults" rule from issue #37 —
/// adding a section header alone never erases unrelated knobs.
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
    ///
    /// When `overlayTheme != .system` AND `overlayTheme != .random`,
    /// the theme palette's accent takes precedence. Users who want
    /// the theme's body colors but a different accent (e.g. nord's
    /// frost-blue pills with a hot-pink highlight) set both knobs.
    public let overlayAccent: String

    /// Pill color palette + typography preset — picks pill background
    /// tint, accent (border/matched-glow/typed-prefix), text color,
    /// miss-flash color, and font family in one knob. Mirrors facet's
    /// `[overlay] theme` vocabulary so users carrying a facet config
    /// see the same names. Default `.system` keeps the historical
    /// adaptive look (NSColor.controlAccentColor, dark pill tint).
    public let overlayTheme: Theme

    /// Geometric preset for the pill body. `.pill` (default) is the
    /// historical 10pt rounded rect; alternates let users dial
    /// density (`.square` is denser, `.underline` removes the body
    /// entirely for minimalists). Orthogonal to `overlayTheme` —
    /// the palette + the shape combine freely.
    public let pillShape: PillShape

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

    /// `true` (default) to render the AX-bound keyboard shortcut
    /// on `--menu` pills (issue #58) as a right-aligned suffix
    /// (e.g. `1 File > Quit  ⌘Q`). `false` to hide the annotation
    /// — useful when the menu items already include their own
    /// shortcut hint in the title, or for screenshot work where
    /// the annotation clutters.
    public let overlayShowShortcuts: Bool

    /// Hold-to-peek key: while held, the overlay temporarily hides
    /// so the user can see the UI underneath the hint pills. Release
    /// to restore. Single key, no modifiers (e.g. `"space"`, `"tab"`).
    /// Empty disables the feature. Default `"space"`. Unknown names
    /// silently fall back to disabled per typo-tolerance.
    public let overlayPeekKey: String

    /// `true` to draw a small modifier-glyph badge in the top-right
    /// corner of every pill when the user holds Cmd / Shift / Alt
    /// during hint mode. Confirms the action mode that will fire on
    /// resolve (Cmd → copyTitle, Shift → rightClick, Alt → focus,
    /// Cmd+Shift → pressContinuous). False (default) keeps pills
    /// clean — same UX as before this knob existed.
    public let showModifierBadge: Bool

    /// What pills do as the overlay APPEARS — symmetric with
    /// `matchEffect` / `unmatchEffect` / `narrowEffect`. Default
    /// `.pop` is the historical 150ms scale-in. Use `.none` to
    /// suppress entrance animation entirely.
    public let appearEffect: AppearEffect

    /// What perch does to the WINNING pill at hint-resolve time.
    /// Ports wand's `[gesture.effect] match` vocabulary, scoped to
    /// perch's single-pill resolve. Default `.none` keeps the snappy
    /// "pill vanishes the instant AXPress fires" UX; `.fade` /
    /// `.explode` decorate the moment for screencasts or first-time
    /// users. Non-winning pills always dismiss immediately.
    public let matchEffect: MatchEffect

    /// What perch does on a missed keypress / non-letter input.
    /// The existing 200ms red-flash is the baseline; this knob
    /// layers ADDITIONAL motion (`.shake`) or replaces the hold
    /// with a fade (`.fade`). Off (`.none`) → historical red-flash
    /// behavior.
    public let unmatchEffect: UnmatchEffect

    /// What perch does to pills that get FILTERED OUT mid-typing
    /// (the user typed `a` while `aa, ab, ac, xx` were on screen —
    /// `xx` disappears because its label doesn't start with the
    /// typed prefix). Off (`.none`) → instant removal (the
    /// historical behavior). Uses the same kind vocabulary as
    /// `matchEffect` since the underlying problem is the same:
    /// "this pill is going away, give it a visual exit".
    public let narrowEffect: MatchEffect

    /// Pill border neon preset — ports facet's `[border]` vocabulary
    /// onto perch's per-pill border. `.off` keeps the existing 1pt
    /// accent-tinted hairline; the other kinds (neon / cyber / vapor /
    /// kawaii / rainbow / random) paint a brighter colored border
    /// optionally with bloom + hue-cycle over time. Layered on top
    /// of `overlayTheme` so the body palette stays the same.
    public let borderEffect: BorderEffect

    /// `true` adds an NSShadow glow under the border so it reads
    /// like a real neon tube; `false` keeps the border flat.
    /// Only takes effect when `borderEffect != .off`.
    public let borderGlow: Bool

    /// Border line width in points. Clamped 0.5..30. Default 1.5
    /// (matches facet's default and pairs cleanly with the 10pt
    /// pill corner radius).
    public let borderWidth: Double

    /// Hue / palette rotation period in seconds. The painter
    /// rotates the border's hue around the color wheel over this
    /// period, so a 3-second cycle returns to the same color
    /// every 3 seconds. Clamped 1..120. Set to 0 to lock the
    /// color (rainbow then collapses to a static white border).
    public let borderCycleSeconds: Double

    /// Magnitude scaler for `matchEffect` / `unmatchEffect` /
    /// `narrowEffect`. Ports wand's `intensity` vocabulary verbatim.
    /// Affects spatial dimension (explode scale, shake amplitude)
    /// but not duration — that's `effectDurationScale` below.
    public let effectIntensity: EffectIntensity

    /// Multiplier on every animation duration (match / unmatch /
    /// narrow). 1.0 = the calibrated baseline (120-220ms depending
    /// on kind). 2.0 doubles every duration so the user can
    /// actually SEE the effect; 0.5 halves for the snappy crowd.
    /// Clamped to 0.1..5.0 per typo-tolerance.
    ///
    /// Unmatch's underlying red-flash window stretches with the
    /// same scale — without that, a 0.5× scale would tear the
    /// flash down before the animation peaks.
    public let effectDurationScale: Double

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

    /// Role allow-list used by `AXUIElementSource` while walking
    /// inside an `AXWebArea` subtree. When `[behavior.web].roles`
    /// is unset, this mirrors `roles` (the native default) — opt-in
    /// only. Add `Heading`, `Combobox` here to surface web-specific
    /// nav targets without polluting native AppKit hint sets.
    public let webRoles: [String]

    /// Per-bundle-id overrides for the `[behavior]` knobs that vary
    /// usefully across apps: `roles`, `min-size`, `auto-click-on-unique`.
    /// Keyed by exact bundle id (`"com.google.Chrome"`); resolved at
    /// hint-mode entry against `NSWorkspace.frontmostApplication`.
    /// Sections that omit a key fall through to the global value
    /// (typo-tolerance — a per-app section with only `min-size` set
    /// does NOT erase the global `roles`).
    public let perApp: [String: BehaviorOverrides]

    // MARK: - [regional]

    /// Min frame width for regional-mode containers (issue #34
    /// follow-up). Default 200 — articles / sidebars / panes are
    /// usually wider than this; smaller bumps the regional set
    /// toward leaf-sized containers, which is hint mode's domain.
    /// Clamped to `>= 0`.
    public let regionalMinWidth: Double

    /// Min frame height for regional-mode containers. Default 100 —
    /// articles are wide but not tall, so the floor is intentionally
    /// asymmetric with `regionalMinWidth`. Clamped to `>= 0`.
    public let regionalMinHeight: Double

    // MARK: - [grid]

    /// Columns in the `--grid` overlay (issue #66 / M4-α). The
    /// screen union is divided into `gridCols × gridRows` cells;
    /// each cell gets a label via the standard `Labeler.assign(...)`
    /// (so the alphabet stays consistent with hint mode). Default
    /// 12×8 — a 4K monitor at this density gives ~160×135 px cells,
    /// which is "close enough" for a single-step pick before
    /// recursive grid (M4-β) drills deeper.
    /// Clamped to `2..32` per typo-tolerance; values outside fall
    /// back to the defaults.
    public let gridCols: Int

    /// Rows in the `--grid` overlay. See `gridCols`.
    public let gridRows: Int

    /// Threshold for `,g` chord (issue #74 / M5+) — only elements
    /// at least this size on BOTH axes nest into a sub-grid. For
    /// anything smaller, the chord falls through to AXPress
    /// because subdividing a button-sized element with another
    /// grid is meaningless. Default 100×100 (catches textareas /
    /// frames / scroll regions, excludes most buttons /
    /// menuitems). Clamped to `1..1000` per typo-tolerance.
    public let gridNestMinSize: Double

    /// Max subdivision depth for `--rgrid` (issue #67 / M4-β).
    /// Default 3 — `cols × rows × depth` cells of effective
    /// addressable points: 12×8×3 = 288 levels, each level
    /// halving the cell size, so 3 drills on a 4K screen lands
    /// inside a ~5px region. Clamped to `1..5`; depth=1
    /// degenerates to `--grid` (single level), depth=5 hits
    /// sub-pixel territory long before becoming useful.
    public let gridMaxDepth: Int

    // MARK: - [chord]

    /// Chord-suffix leader character (issue #57). Empty (the
    /// default) **disables chord mode** so the bare-resolve UX
    /// stays snappy. Set to `","` (or another single char) to
    /// enable: after a bare-modifier hint resolve, perch holds
    /// the `.press` dispatch for `chordTimeoutMs` waiting for
    /// `<leader><action-char>` (e.g. `,o` → revealInFinder).
    /// Modifier-driven action mode (Cmd/Shift/Alt) is unaffected
    /// — chord is only the modifier-less alternative.
    /// Lowercased so the lookup matches the lowercased keypress.
    public let chordLeader: String

    /// Chord-suffix timeout in milliseconds. Resets between the
    /// leader keypress and the action character — so a slow
    /// typist can take up to `2 × chordTimeoutMs` total. Default
    /// 600ms keeps the deferred-press feel under a beat. Capped
    /// at 5000ms (5s) so a typo can't strand a dispatch.
    public let chordTimeoutMs: Double

    // MARK: - [search]

    /// Synonym groups for `SearchMode` / `MenuMode`. Each entry is
    /// one group: the key plus every value form expand to each
    /// other at match time, so a user can type `rm` and find a
    /// "Delete" item without having to remember which form the
    /// table's key uses. Empty when the user hasn't configured any —
    /// matching falls back to plain fuzzy subsequence.
    /// See `SearchFilter.rank(...)` for the consumer.
    public let searchSynonyms: [String: [String]]

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
        overlayTheme: .system,
        pillShape: .pill,
        overlayFontSize: 15,
        overlayBlurEnabled: true,
        overlayAnimEnabled: true,
        overlayShowShortcuts: true,
        overlayPeekKey: "space",
        showModifierBadge: false,
        appearEffect: .pop,
        matchEffect: .none,
        unmatchEffect: .none,
        narrowEffect: .none,
        borderEffect: .off,
        borderGlow: true,
        borderWidth: 1.5,
        borderCycleSeconds: 3.0,
        effectIntensity: .normal,
        effectDurationScale: 1.0,
        autoClickOnUnique: true,
        roles: defaultRoles,
        excludeApps: [],
        minSize: 6,
        webRoles: defaultRoles,
        perApp: [:],
        regionalMinWidth: 200,
        regionalMinHeight: 100,
        gridCols: 12,
        gridRows: 8,
        gridNestMinSize: 100,
        gridMaxDepth: 3,
        chordLeader: "",
        chordTimeoutMs: 600,
        searchSynonyms: [:]
    )

    // MARK: - Per-app resolution

    /// Effective `roles` allow-list for `bundleID`. Falls back to
    /// the global `roles` when no override is configured or when
    /// the override section omits this key.
    public func effectiveRoles(for bundleID: String?) -> [String] {
        guard let bid = bundleID,
              let o = perApp[bid],
              let r = o.roles else { return roles }
        return r
    }

    /// Effective `min-size` floor for `bundleID`. Falls back to the
    /// global value when no override is configured or the section
    /// omits the key.
    public func effectiveMinSize(for bundleID: String?) -> Double {
        guard let bid = bundleID,
              let o = perApp[bid],
              let m = o.minSize else { return minSize }
        return m
    }

    /// Effective `auto-click-on-unique` flag for `bundleID`. Same
    /// per-app fallback rule as the other resolvers — overrides
    /// don't erase the global default unless the user explicitly
    /// sets the key.
    public func effectiveAutoClickOnUnique(for bundleID: String?) -> Bool {
        guard let bid = bundleID,
              let o = perApp[bid],
              let b = o.autoClickOnUnique else { return autoClickOnUnique }
        return b
    }

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
        // Theme palette — unknown names clamp to `.system` per
        // typo-tolerance. `.random` is resolved once at parse time
        // so the chosen palette stays stable for the daemon's life
        // (each `--reload` rolls fresh).
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
        // Peek key: trim + lowercase, empty = disabled. Unknown
        // names also resolve to disabled at adapter load time
        // (HotkeyMonitor.keyCode(for:) returns nil) — same
        // typo-tolerance as the cancel key.
        let peekKey = (doc["overlay"]?["peek-key"]?.asString)
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            ?? "space"
        let showBadge = doc["overlay"]?["show-modifier-badge"]?.asBool
            ?? false

        // [overlay.border] — neon border preset. Same flat-key
        // shape as [overlay.effect]. All knobs clamp / fall back
        // to defaults per typo-tolerance.
        let borderSection = doc["overlay.border"]
        let borderEff = (borderSection?["effect"]?.asString)
            .flatMap(BorderEffect.parse)?.resolvingRandom() ?? .off
        let borderGlow = borderSection?["glow"]?.asBool ?? true
        let borderWidth: Double = {
            guard let raw = borderSection?["width"]?.asDouble
            else { return 1.5 }
            return raw >= 0.5 && raw <= 30 ? raw : 1.5
        }()
        let borderCycle: Double = {
            guard let raw = borderSection?["cycle-seconds"]?.asDouble
            else { return 3.0 }
            return raw >= 0 && raw <= 120 ? raw : 3.0
        }()

        // [overlay.effect] — wand-style match / unmatch / intensity.
        // Same flat-key shape as [behavior.web]: TOML's dotted-table
        // header lands as a single `"overlay.effect"` key in our
        // hand-rolled parser. Unknown kinds clamp per typo-tolerance.
        let effSection = doc["overlay.effect"]
        let appearEff = (effSection?["appear"]?.asString)
            .flatMap(AppearEffect.parse)?.resolvingRandom() ?? .pop
        let matchEff = (effSection?["match"]?.asString)
            .flatMap(MatchEffect.parse) ?? .none
        let unmatchEff = (effSection?["unmatch"]?.asString)
            .flatMap(UnmatchEffect.parse) ?? .none
        let narrowEff = (effSection?["narrow"]?.asString)
            .flatMap(MatchEffect.parse) ?? .none
        let intensity = (effSection?["intensity"]?.asString)
            .flatMap(EffectIntensity.parse) ?? .normal
        // duration-scale clamp 0.1..5.0 per typo-tolerance: values
        // outside that range fall back to 1.0 (the baseline) so a
        // misconfigured user never gets stuck with a 30-second
        // fade or a 1ms invisible flash.
        let durScale: Double = {
            guard let raw = effSection?["duration-scale"]?.asDouble
            else { return 1.0 }
            return raw >= 0.1 && raw <= 5.0 ? raw : 1.0
        }()

        let autoClick = doc["behavior"]?["auto-click-on-unique"]?.asBool ?? true
        let roles = (doc["behavior"]?["roles"]?.asStringArray)
            .map { $0.filter { !$0.isEmpty } } ?? defaultRoles
        let excludes = doc["behavior"]?["exclude-apps"]?.asStringArray ?? []
        // Clamp negatives to 0 (per typo-tolerance policy);
        // 0 disables the size floor entirely.
        let minSize = (doc["behavior"]?["min-size"]?.asDouble).map {
            max(0, $0)
        } ?? 6

        // Web-context role list — `[behavior.web].roles`. TOML
        // dotted-table headers land as flat keys in our parser, so
        // it's `doc["behavior.web"]?[...]` (NOT
        // `doc["behavior"]?["web"]?[...]`). Falls back to the
        // native `roles` list so users who don't opt in see no
        // behaviour change.
        let webRoles = (doc["behavior.web"]?["roles"]?.asStringArray)
            .map { $0.filter { !$0.isEmpty } } ?? roles

        // Per-app overrides — `[behavior."<bundle-id>"]` sections.
        // Same flat-key shape as `[behavior.web]`: the parser
        // preserves the quotes, so the key is literally
        // `behavior."com.foo.bar"`. Strip the wrapper, treat the
        // inner string as the bundle id. Empty bundle id or empty
        // override section is dropped — typo-tolerance, never
        // crash on a malformed user config.
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
            // Skip a section with the header present but no
            // recognised key — adds nothing, would noise up the
            // `--validate` count.
            if r == nil, m == nil, a == nil { continue }
            perApp[bid] = BehaviorOverrides(
                roles: r, minSize: m, autoClickOnUnique: a)
        }

        // Regional mode frame floor (#34 follow-up). Both clamp to
        // `>= 0` per typo-tolerance; defaults match the literals the
        // first regional implementation used (200×100).
        let regionalMinW = (doc["regional"]?["min-width"]?.asDouble)
            .map { max(0, $0) } ?? 200
        let regionalMinH = (doc["regional"]?["min-height"]?.asDouble)
            .map { max(0, $0) } ?? 100

        // Grid mode (#66 / M4-α). Both axes clamp to 2..32 per
        // typo-tolerance; values outside fall back to defaults
        // (12×8). Below 2 there's nothing to subdivide; above 32 the
        // labels become unreadable on real-world displays.
        let gridCols: Int = {
            guard let raw = doc["grid"]?["cols"]?.asInt else { return 12 }
            return raw >= 2 && raw <= 32 ? raw : 12
        }()
        let gridRows: Int = {
            guard let raw = doc["grid"]?["rows"]?.asInt else { return 8 }
            return raw >= 2 && raw <= 32 ? raw : 8
        }()
        let gridMaxDepth: Int = {
            guard let raw = doc["grid"]?["max-depth"]?.asInt
            else { return 3 }
            return raw >= 1 && raw <= 5 ? raw : 3
        }()
        let gridNestMinSize: Double = {
            guard let raw = doc["grid"]?["nest-min-size"]?.asDouble
            else { return 100 }
            return raw >= 1 && raw <= 1000 ? raw : 100
        }()

        // Chord-suffix knobs (#57). Leader is normalised to a
        // single lowercased character; empty (the default) means
        // chord mode is OFF and the bare-resolve UX is unchanged.
        // Multi-char values are clamped to the first character so
        // a typo like `leader = "comma"` doesn't silently break
        // chord lookups — the first letter ("c") at least lines
        // up with one of the action chars.
        let chordLeader: String = {
            guard let raw = doc["chord"]?["leader"]?.asString else {
                return ""
            }
            let trimmed = raw
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            return String(trimmed.prefix(1))
        }()
        let chordTimeoutMs = (doc["chord"]?["timeout-ms"]?.asDouble)
            .map { max(0, min($0, 5000)) } ?? 600

        // Search synonyms (#53) — `[search.synonyms]` parses as a
        // flat `"search.synonyms"` section (same shape as
        // `[behavior.web]`). Every value is a string array; entries
        // with empty key or empty value list are dropped per
        // typo-tolerance. Keys lowercased so lookup is canonical.
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

        return PerchConfig(
            hotkey: hk,
            cancelKey: cancel,
            alphabet: alphabet,
            prioritiseCenter: priority,
            overlayAccent: accent,
            overlayTheme: theme,
            pillShape: shape,
            overlayFontSize: size,
            overlayBlurEnabled: blur,
            overlayAnimEnabled: anim,
            overlayShowShortcuts: showShortcuts,
            overlayPeekKey: peekKey,
            showModifierBadge: showBadge,
            appearEffect: appearEff,
            matchEffect: matchEff,
            unmatchEffect: unmatchEff,
            narrowEffect: narrowEff,
            borderEffect: borderEff,
            borderGlow: borderGlow,
            borderWidth: borderWidth,
            borderCycleSeconds: borderCycle,
            effectIntensity: intensity,
            effectDurationScale: durScale,
            autoClickOnUnique: autoClick,
            roles: roles,
            excludeApps: excludes,
            minSize: minSize,
            webRoles: webRoles,
            perApp: perApp,
            regionalMinWidth: regionalMinW,
            regionalMinHeight: regionalMinH,
            gridCols: gridCols,
            gridRows: gridRows,
            gridNestMinSize: gridNestMinSize,
            gridMaxDepth: gridMaxDepth,
            chordLeader: chordLeader,
            chordTimeoutMs: chordTimeoutMs,
            searchSynonyms: synonyms)
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

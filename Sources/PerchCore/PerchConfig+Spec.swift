// PerchConfig+Spec — the ONE declarative description of perch's
// `config.toml` surface. sill's `ConfigSchema.Spec` turns this single
// source into BOTH:
//
//   • the decode of the UNIFORM scalar sections (`PerchConfig.parse` →
//     `configSpec.decode` into a flat `Staged` struct the sub-structs are
//     then assembled from)
//   • the JSON Schema (`perch --emit-schema`) taplo uses for editor
//     completion + validation
//
// so a uniform key can never be in the parser but missing from the schema
// (or vice-versa). Each `apply` closure reproduces the old hand-written
// read EXACTLY (same `Toml.Value` accessor, same clamp / range-fallback,
// write-only-when-present), so the resolved config is byte-identical — see
// the parity harness in the config-schema slice + ConfigSchemaDriftTests.
//
// Enum DOMAINS come from the single sources of truth: sill's
// `canonicalThemeNames` + `EffectIntensity` (+ `parseColorToken`'s grammar,
// described in prose) and perch's own enums (`PillShape` / `AppearEffect` /
// `MatchEffect` / `UnmatchEffect` / `BorderEffect` / `ModifierBadgeStyle`,
// all `CaseIterable`). Numeric `min`/`max` mirror the range checks in the
// section parsers (advisory in the editor; perch still clamps at runtime so
// a typo can't break the daemon).
//
// NON-uniform bits stay BESPOKE in PerchConfig (decoded straight from the
// flat `doc`), DESCRIBED here for the schema only:
//   • `[overlay].theme` — custom-palette interplay (`.dynamicTable`
//     `[overlay.themes.<name>]` wins over the catalog), `random` resolves
//     to a concrete name at parse → no static enum (would false-flag a
//     valid custom name).
//   • `[overlay].show-modifier-badge` — bool-back-compat + a parse-time log.
//   • `[hotkey].active` — `HotkeyCombo.parse` (modifier+key grammar).
//   • `[behavior."<bundle-id>"]` per-app overrides (literal-quote section
//     names) — `.dynamicTable`.
//   • `[search.synonyms]` — dynamic key table — `.dynamicTable`.
//   • `[overlay.themes.<name>]` custom palettes — `.dynamicTable`.

import ConfigSchema
import Foundation
import Palette
import Toml

public extension PerchConfig {

    /// Mutable staging struct the declarative spec decodes the UNIFORM
    /// scalar sections into. Seeded with the SAME built-in defaults the
    /// old section parsers fell back to, so "write only when the key is
    /// present" reproduces every default path exactly. Sub-structs are
    /// assembled from this after `configSpec.decode` (the bespoke
    /// non-uniform fields are filled separately from the flat `doc`).
    struct Staged {
        // [hotkey] (active is bespoke — HotkeyCombo grammar)
        var cancel = PerchConfig.defaultCancelKey
        // [labels] (alphabet is bespoke — sanitiseAlphabet)
        var prioritiseCenter = true
        // [overlay] uniform scalars (theme / show-modifier-badge bespoke)
        var accent = "system"
        var pillShape: PillShape = .pill
        var fontSize: Double = 15
        var blurEnabled = true
        var animEnabled = true
        var showShortcuts = true
        var peekKey = "space"
        // [overlay.effect]
        var appear: AppearEffect = .pop
        var match: MatchEffect = .off
        var unmatch: UnmatchEffect = .off
        var narrow: MatchEffect = .off
        var intensity: EffectIntensity = .normal
        var durationScale: Double = 1.0
        // [overlay.border]
        var borderEffect: BorderEffect = .off
        var borderGlow = true
        var borderWidth: Double = 1.5
        var borderCycleSeconds: Double = 3.0
        // [overlay.sound]
        var soundMatch = ""
        var soundUnmatch = ""
        var soundActivate = ""
        var volume: Double = 0.5
        // [behavior] uniform scalars (roles/web-roles/per-app bespoke)
        var autoClickOnUnique = true
        var minSize: Double = 6
        // [exclude]
        var excludeApps: [String] = []
        // [regional]
        var regMinWidth: Double = 200
        var regMinHeight: Double = 100
        // [grid]
        var gridCols = 12
        var gridRows = 8
        var recursiveCols = 3
        var recursiveRows = 3
        var maxDepth = 3
        var nestMinSize: Double = 100
        // [chord] (leader is bespoke — single-char prefix)
        var timeoutMs: Double = 600

        public init() {}
    }

    /// The single declarative spec. Drives the uniform-section decode and
    /// `--emit-schema`. Computed (not a stored `let`) so it needn't be
    /// `Sendable` — the `apply` closures capture keypaths; rebuilding the
    /// fields on the rare config (re)load is free.
    ///
    /// The section list is assembled from per-section computed pieces
    /// (`Section` + `[Field]` are typed explicitly): one giant array literal
    /// of closure-bearing builder calls blows the Swift type-checker's
    /// inference budget ("unable to type-check in reasonable time"), so each
    /// section is its own small, fast-to-check expression.
    static var configSpec: ConfigSchema.Spec<Staged> {
        ConfigSchema.Spec<Staged>(
            title: "perch config.toml",
            sections: [
                hotkeySection, labelsSection, overlaySection,
                overlayThemesSection, overlayEffectSection, overlayBorderSection,
                overlaySoundSection, excludeSection, behaviorSection,
                behaviorWebSection, behaviorPerAppSection, regionalSection,
                gridSection, chordSection, searchSynonymsSection,
            ])
    }

    private typealias Sec = ConfigSchema.Section<Staged>
    private typealias Fld = ConfigSchema.Field<Staged>

    private static var hotkeySection: Sec {
        .init("hotkey", doc: "Activation + cancel binding.", fields: [
                // active = "shift+space" — HotkeyCombo grammar (modifiers
                // joined with `+`, then a key); parsed bespoke, schema-only.
                .descOnly("active", default: .string("shift+space"),
                    doc: "Global hotkey that activates hint mode. "
                       + "Modifiers shift|ctrl|alt|cmd joined with `+`, "
                       + "then a key (e.g. \"shift+space\", \"ctrl+alt+j\")."),
                // cancel — trim + lowercase; empty falls back to default.
                .strLowerNonEmpty("cancel", \.cancel, default: "esc",
                    doc: "Key that dismisses an active overlay (single key, "
                       + "no modifiers). Unknown names fall back to esc."),
            ])
    }

    private static var labelsSection: Sec {
        .init("labels", doc: "Label alphabet + assignment priority.",
                  fields: [
                .descOnly("alphabet", default: .string(defaultAlphabet),
                    doc: "Characters used to label elements, in priority "
                       + "order. De-duplicated, non-letters dropped, "
                       + "lowercased; empty after cleaning = default."),
                .bool("prioritise-center", \.prioritiseCenter, default: true,
                    doc: "Assign the easiest keys to elements closest to "
                       + "screen center when elements outnumber first-tier "
                       + "letters."),
            ])
    }

    private static var overlaySection: Sec {
        // The `fields:` array is a separately-typed `[Fld]` local: each
        // closure-bearing builder call resolves against one concrete element
        // type, so the type-checker doesn't explode on a 9-field literal
        // nested inside the `.init` argument context.
        let badgeDomain = ModifierBadgeStyle.allCases.map(\.rawValue)
            + ["true", "false", "yes", "no"]
        let fields: [Fld] = [
            // theme — custom-palette interplay + `random`; bespoke.
            // No enum: a `[overlay.themes.<name>]` custom name is valid
            // but runtime-dynamic, so a static enum would false-flag it.
            .descOnly("theme", default: .string("system"),
                doc: "Pill color/typography theme. A sill catalog name "
                   + "(terminal / dracula / github-dark / … / system / "
                   + "random) OR a [overlay.themes.<name>] custom palette "
                   + "name. Unknown clamps to \"system\"."),
            // accent — "system" / "accent" alias, or a sill colour token.
            .strSanitised("accent", \.accent, sanitise: Self.sanitiseAccent,
                default: "system",
                doc: "Accent override layered over the theme. \"system\" "
                   + "(default) keeps the theme accent; a sill colour "
                   + "token (named / #rgb / #rrggbb / #rrggbbaa) overrides "
                   + "it. Unrecognised falls back to \"system\"."),
            .enumStr("pill-shape", \.pillShape, PillShape.parse,
                domain: PillShape.allCases.map(\.rawValue), default: "pill",
                doc: "Pill geometry: pill / square / circle / underline / "
                   + "tag. Unknown clamps to \"pill\"."),
            .dblClampedFallback("font-size", \.fontSize, min: 8, max: 32,
                default: 15,
                doc: "Pill label font size (pt). Clamped 8..32."),
            .bool("blur-enabled", \.blurEnabled, default: true,
                doc: "Frosted-glass NSVisualEffectView under the pills; "
                   + "false = solid dark fill."),
            .bool("anim-enabled", \.animEnabled, default: true,
                doc: "Global motion kill-switch — false collapses every "
                   + "effect to its instant baseline."),
            .bool("shortcut-badge", \.showShortcuts, default: true,
                doc: "Show AX-bound keyboard-shortcut annotations on "
                   + "--menu pills."),
            .strLower("peek-key", \.peekKey, default: "space",
                doc: "Hold-to-peek key (trimmed + lowercased). Empty "
                   + "disables; unknown names disable silently."),
            // show-modifier-badge — bool back-compat + a log; bespoke.
            .descOnly("show-modifier-badge", domain: badgeDomain,
                default: .string("off"),
                doc: "Modifier-badge corner annotation: off / glyph / "
                   + "action. Legacy bools true/false map to glyph/off."),
        ]
        return .init("overlay", doc: "Pill rendering knobs (theme + shape + "
            + "font + a few overlay behaviour flags).", fields: fields)
    }

    private static var overlayThemesSection: Sec {
        .init("overlay.themes", kind: .dynamicTable,
                doc: "`[overlay.themes.<name>]` user-defined palettes — set "
                   + "`[overlay].theme = \"<name>\"` to select one. Keys: "
                   + "pill-bg / accent / text / miss (colour tokens), "
                   + "pill-bg-alpha (0..1), font (mono / rounded / system / "
                   + "menu). Names shadowing a built-in are ignored.")
    }

    private static var overlayEffectSection: Sec {
        .init("overlay.effect", doc: "Hint-flow animations (appear / "
                + "match / unmatch / narrow) plus shared knobs.", fields: [
                .enumStrResolved("appear", \.appear, AppearEffect.parse,
                    resolve: { $0.resolvingRandom() },
                    domain: AppearEffect.allCases.map(\.rawValue),
                    default: "pop",
                    doc: "Entrance animation as the overlay appears: off / "
                       + "pop / cascade / fade-in / drop-in / bloom / random."),
                .enumStr("match", \.match, MatchEffect.parse,
                    domain: MatchEffect.allCases.map(\.rawValue), default: "off",
                    doc: "Animation on the winning pill at resolve. Unknown "
                       + "clamps to \"off\"."),
                .enumStr("unmatch", \.unmatch, UnmatchEffect.parse,
                    domain: UnmatchEffect.allCases.map(\.rawValue),
                    default: "off",
                    doc: "Animation layered on the 200ms red flash for a "
                       + "missed key. Unknown clamps to \"off\"."),
                .enumStr("narrow", \.narrow, MatchEffect.parse,
                    domain: MatchEffect.allCases.map(\.rawValue), default: "off",
                    doc: "Per-pill exit animation when a typed prefix filters "
                       + "a pill out. fireworks/confetti downgrade to fade at "
                       + "runtime."),
                .enumStr("intensity", \.intensity, EffectIntensity.parse,
                    domain: EffectIntensity.allCases.map(\.rawValue),
                    default: "normal",
                    doc: "Spatial magnitude scaler: subtle / normal / bold / "
                       + "wild (does not lengthen duration)."),
                .dblRangeFallback("duration-scale", \.durationScale,
                    min: 0.1, max: 5.0, default: 1.0,
                    doc: "Multiplier on every animation duration. Clamped "
                       + "0.1..5.0; out-of-range falls back to 1.0."),
            ])
    }

    private static var overlayBorderSection: Sec {
        .init("overlay.border", doc: "Neon-border preset around each pill.",
                  fields: [
                .enumStrResolved("effect", \.borderEffect, BorderEffect.parse,
                    resolve: { $0.resolvingRandom() },
                    domain: BorderEffect.allCases.map(\.rawValue),
                    default: "off",
                    doc: "Border preset: off / neon / cyber / vapor / kawaii / "
                       + "rainbow / random."),
                .bool("glow", \.borderGlow, default: true,
                    doc: "NSShadow bloom under the stroke (the neon-tube feel)."),
                .dblRangeFallback("width", \.borderWidth, min: 0.5, max: 30,
                    default: 1.5,
                    doc: "Border line width (pt). Clamped 0.5..30; "
                       + "out-of-range falls back to 1.5."),
                // color-cycle-ms — ms in config, seconds internally; the
                // range fallback is on the RAW ms then /1000.
                .msToSecondsFallback("color-cycle-ms", \.borderCycleSeconds,
                    min: 0, max: 120_000, defaultMs: 3000,
                    doc: "Hue rotation period (integer ms). Clamped 0..120000 "
                       + "(0 locks the color); out-of-range falls back to "
                       + "3000ms."),
            ])
    }

    private static var overlaySoundSection: Sec {
        .init("overlay.sound", doc: "Audio feedback. match / unmatch / "
                + "activate take a macOS system-sound name OR a file path "
                + "(tilde-expanded); empty silences.", fields: [
                .str("match", \.soundMatch, default: "",
                    doc: "Sound on hint resolve (system-sound name or path)."),
                .str("unmatch", \.soundUnmatch, default: "",
                    doc: "Sound on a missed keypress."),
                .str("activate", \.soundActivate, default: "",
                    doc: "Sound when hint mode activates."),
                .dblClampedFallback("volume", \.volume, min: 0, max: 1,
                    default: 0.5,
                    doc: "Master volume 0..1."),
            ])
    }

    private static var excludeSection: Sec {
        .init("exclude", doc: "Bundle IDs perch never activates over.",
                  fields: [
                .strArray("apps", \.excludeApps, default: [],
                    doc: "Bundle-id globs (`*` / `?`) perch ignores; `[]` = "
                       + "none."),
            ])
    }

    private static var behaviorSection: Sec {
        .init("behavior", doc: "AX walk + dispatch behaviour.", fields: [
                .bool("auto-click-on-unique", \.autoClickOnUnique, default: true,
                    doc: "Auto-click when one candidate remains after partial "
                       + "input."),
                // roles — array; empty entries dropped. Bespoke (also feeds
                // web-roles' fallback), described here for the schema.
                .descArray("roles", item: nil, default: defaultRoles,
                    doc: "AX roles to label (no `AX` prefix). Empty entries "
                       + "dropped."),
                .dblMinFallback("min-size", \.minSize, min: 0, default: 6,
                    doc: "Min frame size (pt, either axis) for an element to "
                       + "be labeled. Clamped >= 0. 0 disables."),
            ])
    }

    private static var behaviorWebSection: Sec {
        .init("behavior.web", doc: "Role allow-list used inside an "
                + "AXWebArea subtree; falls back to [behavior].roles.",
                  fields: [
                .descArray("roles", item: nil,
                    doc: "Web-context AX roles to label; unset inherits "
                       + "[behavior].roles."),
            ])
    }

    private static var behaviorPerAppSection: Sec {
        // Per-app `[behavior."<bundle-id>"]` overrides — literal-quote
        // dynamic section names, parsed bespoke; schema-only here.
        .init("behavior.\"<bundle-id>\"", kind: .dynamicTable,
                doc: "`[behavior.\"<bundle-id>\"]` per-app overrides — set "
                   + "only the keys to override: roles / min-size / "
                   + "auto-click-on-unique / appear-effect / match-effect / "
                   + "unmatch-effect / narrow-effect. Missing keys inherit "
                   + "the global [behavior] / [overlay.effect] value.")
    }

    private static var regionalSection: Sec {
        .init("regional", doc: "Frame floor for regional-mode container "
                + "labeling.", fields: [
                .dblMinFallback("min-width", \.regMinWidth, min: 0, default: 200,
                    doc: "Min container width (pt) to label. Clamped >= 0."),
                .dblMinFallback("min-height", \.regMinHeight, min: 0,
                    default: 100,
                    doc: "Min container height (pt) to label. Clamped >= 0."),
            ])
    }

    private static var gridSection: Sec {
        .init("grid", doc: "Single-pass + recursive grid density + "
                + "nested-grid threshold.", fields: [
                .intRangeFallback("cols", \.gridCols, min: 2, max: 32,
                    default: 12,
                    doc: "Single-pass --grid columns. Clamped 2..32."),
                .intRangeFallback("rows", \.gridRows, min: 2, max: 32,
                    default: 8,
                    doc: "Single-pass --grid rows. Clamped 2..32."),
                .intRangeFallback("recursive-cols", \.recursiveCols,
                    min: 2, max: 32, default: 3,
                    doc: "--rgrid columns per drill level. Clamped 2..32."),
                .intRangeFallback("recursive-rows", \.recursiveRows,
                    min: 2, max: 32, default: 3,
                    doc: "--rgrid rows per drill level. Clamped 2..32."),
                .intRangeFallback("max-depth", \.maxDepth, min: 1, max: 10,
                    default: 3,
                    doc: "Max recursive --rgrid drill depth. Clamped 1..10."),
                .dblRangeFallback("nest-min-size", \.nestMinSize,
                    min: 1, max: 1000, default: 100,
                    doc: "`,g` chord falls back to AXPress below this frame "
                       + "floor (pt). Clamped 1..1000."),
            ])
    }

    private static var chordSection: Sec {
        .init("chord", doc: "Chord-suffix action mode (#57).", fields: [
                // leader — single-char prefix; bespoke.
                .descOnly("leader", default: .string(""),
                    doc: "Chord leader (first char only after trim+lowercase). "
                       + "Empty (default) disables chord mode."),
                .dblClampedFallback("timeout-ms", \.timeoutMs, min: 0, max: 5000,
                    default: 600,
                    doc: "Per-phase chord wait (ms). Clamped 0..5000."),
            ])
    }

    private static var searchSynonymsSection: Sec {
        .init("search.synonyms", kind: .dynamicTable,
                doc: "`[search.synonyms]` fuzzy-match expansion table for "
                   + "--search / --menu / --windows / --emoji. Each key maps "
                   + "to a string array of synonyms (bidirectional; the key "
                   + "itself and empties are dropped).")
    }

    // MARK: - JSON Schema (taplo) — emitted from the SAME `configSpec`

    /// The `config.toml` JSON Schema (Draft-07). Drives `perch
    /// --emit-schema` and the sidecar install — emitted by sill's shared
    /// `ConfigSchema.Spec.jsonSchema()` from the one `configSpec`, so it
    /// can never drift from the decode. sill folds perch's genuinely
    /// NESTED headers (`[overlay.effect]`, `[behavior."<id>"]`,
    /// `[search.synonyms]`, …) into the object tree taplo validates the
    /// raw TOML against (generalised in sill 0.9.1 — perch's former local
    /// folder is retired).
    static var jsonSchema: String { configSpec.jsonSchema() }

    /// Where the schema sidecar lives — next to the user config, so a
    /// `#:schema ./config.schema.json` directive resolves on the user's
    /// machine (taplo reads it relative to the .toml's own directory).
    static var schemaPath: String {
        (path as NSString).deletingLastPathComponent + "/config.schema.json"
    }

    /// Write the schema next to the user config. IDEMPOTENT (writes only
    /// when the content differs) so it never churns the file or trips the
    /// watcher (which watches `config.toml`, not this sibling). Creates
    /// `~/.config/perch/` if absent. Best-effort: a failure is non-fatal
    /// (completion just won't resolve), so the daemon never fails to start
    /// over it. Returns true if it actually wrote.
    @discardableResult
    static func installSchema() -> Bool {
        let p = schemaPath
        let dir = (p as NSString).deletingLastPathComponent
        let fm = FileManager.default
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let want = jsonSchema
        if let current = try? String(contentsOfFile: p, encoding: .utf8),
           current == want {
            return false
        }
        return (try? want.write(toFile: p, atomically: true, encoding: .utf8)) != nil
    }

    // MARK: - Shared sanitisers (used by both the spec apply + bespoke decode)

    /// Accept "system" / "accent" alias or a sill colour token; returns the
    /// canonical lowercase token, or `nil` on malformed input so the caller
    /// clamps to "system".
    static func sanitiseAccent(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces).lowercased()
        if t == "system" || t == "accent" { return "system" }
        return parseColorToken(t) != nil ? t : nil
    }

    /// Drop duplicate / non-typeable characters, lowercase; empty after
    /// cleaning → `nil` so the caller applies the default alphabet.
    static func sanitiseAlphabet(_ s: String) -> String? {
        var seen = Set<Character>()
        var out = ""
        for ch in s.lowercased() {
            guard ch.isLetter, !seen.contains(ch) else { continue }
            seen.insert(ch)
            out.append(ch)
        }
        return out.isEmpty ? nil : out
    }
}

// MARK: - Field builders (keypath + Toml accessor → declarative field)

private extension ConfigSchema.Field where Root == PerchConfig.Staged {

    /// Plain string, written as-is when present.
    static func str(_ key: String, _ kp: WritableKeyPath<Root, String>,
                    default def: String, doc: String? = nil) -> Self {
        .init(key: key, kind: .scalar(.string),
              apply: { c, v in if let s = v.asString { c[keyPath: kp] = s } },
              def: .string(def), doc: doc)
    }

    /// String trimmed + lowercased, written as-is (empty allowed).
    static func strLower(_ key: String, _ kp: WritableKeyPath<Root, String>,
                         default def: String, doc: String? = nil) -> Self {
        .init(key: key, kind: .scalar(.string),
              apply: { c, v in
                  if let s = v.asString {
                      c[keyPath: kp] = s.trimmingCharacters(in: .whitespaces)
                          .lowercased()
                  }
              },
              def: .string(def), doc: doc)
    }

    /// String trimmed + lowercased, written only when NON-EMPTY (else the
    /// default seed survives) — the `[hotkey].cancel` shape.
    static func strLowerNonEmpty(
        _ key: String, _ kp: WritableKeyPath<Root, String>,
        default def: String, doc: String? = nil
    ) -> Self {
        .init(key: key, kind: .scalar(.string),
              apply: { c, v in
                  guard let s = v.asString else { return }
                  let t = s.trimmingCharacters(in: .whitespaces).lowercased()
                  if !t.isEmpty { c[keyPath: kp] = t }
              },
              def: .string(def), doc: doc)
    }

    /// String run through a sanitiser; written only when the sanitiser
    /// returns non-nil (else the default seed survives) — `[overlay].accent`.
    static func strSanitised(
        _ key: String, _ kp: WritableKeyPath<Root, String>,
        sanitise: @escaping (String) -> String?,
        default def: String, doc: String? = nil
    ) -> Self {
        .init(key: key, kind: .scalar(.string),
              apply: { c, v in
                  if let s = v.asString, let clean = sanitise(s) {
                      c[keyPath: kp] = clean
                  }
              },
              def: .string(def), doc: doc)
    }

    static func bool(_ key: String, _ kp: WritableKeyPath<Root, Bool>,
                     default def: Bool, doc: String? = nil) -> Self {
        .init(key: key, kind: .scalar(.boolean),
              apply: { c, v in if let b = v.asBool { c[keyPath: kp] = b } },
              def: .bool(def), doc: doc)
    }

    /// String → enum via `parse`; written only when parse succeeds (unknown
    /// leaves the default seed). The schema carries the enum domain.
    static func enumStr<E>(
        _ key: String, _ kp: WritableKeyPath<Root, E>,
        _ parse: @escaping (String) -> E?,
        domain: [String], default def: String, doc: String? = nil
    ) -> Self {
        .init(key: key, kind: .scalar(.string),
              apply: { c, v in
                  if let s = v.asString, let e = parse(s) { c[keyPath: kp] = e }
              },
              domain: domain, def: .string(def), doc: doc)
    }

    /// String → enum via `parse`, then `resolve` (e.g. `resolvingRandom`)
    /// before write — the appear / border-effect shape.
    static func enumStrResolved<E>(
        _ key: String, _ kp: WritableKeyPath<Root, E>,
        _ parse: @escaping (String) -> E?,
        resolve: @escaping (E) -> E,
        domain: [String], default def: String, doc: String? = nil
    ) -> Self {
        .init(key: key, kind: .scalar(.string),
              apply: { c, v in
                  if let s = v.asString, let e = parse(s) {
                      c[keyPath: kp] = resolve(e)
                  }
              },
              domain: domain, def: .string(def), doc: doc)
    }

    /// Integer with a range CHECK then fallback-to-default (NOT min/max
    /// clamp) — perch's grid shape: `raw in [lo, hi] ? raw : default`. A
    /// fractional TOML number fails `asInt`, so the key is treated as
    /// absent (default seed survives) — exactly the old behaviour.
    static func intRangeFallback(
        _ key: String, _ kp: WritableKeyPath<Root, Int>,
        min lo: Int, max hi: Int, default def: Int, doc: String? = nil
    ) -> Self {
        .init(key: key, kind: .scalar(.integer),
              apply: { c, v in
                  guard let n = v.asInt else { return }
                  c[keyPath: kp] = (n >= lo && n <= hi) ? n : def
              },
              def: .int(def), min: Double(lo), max: Double(hi), doc: doc)
    }

    /// Double with a range CHECK then fallback-to-default — the
    /// duration-scale / border-width / nest-min-size shape.
    static func dblRangeFallback(
        _ key: String, _ kp: WritableKeyPath<Root, Double>,
        min lo: Double, max hi: Double, default def: Double, doc: String? = nil
    ) -> Self {
        .init(key: key, kind: .scalar(.number),
              apply: { c, v in
                  guard let n = v.asDouble else { return }
                  c[keyPath: kp] = (n >= lo && n <= hi) ? n : def
              },
              def: .number(def), min: lo, max: hi, doc: doc)
    }

    /// Double min/max CLAMP (not fallback) — the font-size / volume shape:
    /// `min(max(raw, lo), hi)`.
    static func dblClampedFallback(
        _ key: String, _ kp: WritableKeyPath<Root, Double>,
        min lo: Double, max hi: Double, default def: Double, doc: String? = nil
    ) -> Self {
        .init(key: key, kind: .scalar(.number),
              apply: { c, v in
                  if let n = v.asDouble {
                      c[keyPath: kp] = Swift.min(Swift.max(n, lo), hi)
                  }
              },
              def: .number(def), min: lo, max: hi, doc: doc)
    }

    /// Double clamped to a single floor (`max(lo, raw)`) — the min-size /
    /// regional shape.
    static func dblMinFallback(
        _ key: String, _ kp: WritableKeyPath<Root, Double>,
        min lo: Double, default def: Double, doc: String? = nil
    ) -> Self {
        .init(key: key, kind: .scalar(.number),
              apply: { c, v in
                  if let n = v.asDouble { c[keyPath: kp] = Swift.max(lo, n) }
              },
              def: .number(def), min: lo, doc: doc)
    }

    /// Integer-ms in config → seconds field, with a range CHECK on the RAW
    /// ms then `/1000`, else fallback to `defaultMs/1000` — `color-cycle-ms`.
    /// Reads as a number (the old parser used `asDouble`).
    static func msToSecondsFallback(
        _ key: String, _ kp: WritableKeyPath<Root, Double>,
        min lo: Double, max hi: Double, defaultMs: Double, doc: String? = nil
    ) -> Self {
        .init(key: key, kind: .scalar(.integer),
              apply: { c, v in
                  guard let n = v.asDouble else { return }
                  c[keyPath: kp] = (n >= lo && n <= hi) ? n / 1000 : defaultMs / 1000
              },
              def: .int(Int(defaultMs)), min: lo, max: hi, doc: doc)
    }

    /// String array, written as-is when present — `[exclude].apps`.
    static func strArray(_ key: String, _ kp: WritableKeyPath<Root, [String]>,
                         default def: [String], doc: String? = nil) -> Self {
        .init(key: key, kind: .stringArray(item: nil),
              apply: { c, v in if let a = v.asStringArray { c[keyPath: kp] = a } },
              def: .stringArray(def), doc: doc)
    }

    /// Schema-only scalar (no decode — perch parses it bespoke); a no-op
    /// `apply`.
    static func descOnly(_ key: String, _ scalar: ConfigSchema.Scalar = .string,
                         domain: [String]? = nil,
                         default def: ConfigSchema.DefaultValue? = nil,
                         doc: String? = nil) -> Self {
        .init(key: key, kind: .scalar(scalar), apply: { _, _ in },
              domain: domain, def: def, doc: doc)
    }

    /// Schema-only string array (no decode — perch parses it bespoke).
    static func descArray(_ key: String, item: [String]? = nil,
                          default def: [String]? = nil, doc: String? = nil) -> Self {
        .init(key: key, kind: .stringArray(item: item),
              apply: { _, _ in },
              def: def.map { .stringArray($0) }, doc: doc)
    }
}

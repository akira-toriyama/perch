// swift-tools-version:6.0
//
// perch — keyboard-driven UI navigator for macOS.
//
// Architecture is hexagonal (Ports & Adapters), mirroring stroke /
// facet. See docs/architecture.md for the diagram.
//
//   PerchCore             pure logic: label-alphabet assignment,
//                         TOML config, models. No AppKit, no AX,
//                         no global hotkeys. Fully testable.
//
//   PerchAdapterMacOS     real-world glue: AX tree enumeration via
//                         AXUIElementCopyAttributeValue, global hotkey
//                         (Carbon RegisterEventHotKey), overlay panel,
//                         and AXPress dispatch. The ONLY module that
//                         imports AppKit / ApplicationServices.
//
//   PerchAdapterTest      synthetic UIElementSource for end-to-end
//                         tests of label assignment + dispatch flow
//                         without a real frontmost app.
//
//   PerchApp              executable target: @main, CLI argv,
//                         Controller orchestration.
//
// Tests live under Tests/<Module>Tests. The app is config.toml-driven
// (no settings GUI) — the file is the only thing the user looks at.

import PackageDescription

let package = Package(
    name: "perch",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "perch", targets: ["PerchApp"]),
        .library(name: "PerchCore", targets: ["PerchCore"]),
    ],
    dependencies: [
        // Shared theming foundation (plan atelier). perch is the
        // "pure twin": PerchCore consumes the AppKit-free `Palette`
        // module (ThemeSpec / paletteFor / FontKind / canonicalThemeNames),
        // the `Toml` module — the family's ONE TOML implementation (perch's
        // in-tree TOML.swift folded into sill in Phase 1.6, then moved out to
        // the standalone swift-toml-edit repo at sill 0.11.0) — and, since
        // 0.9.0, the `ConfigSchema` module: one
        // declarative `Spec` drives BOTH the config.toml decode and the
        // JSON Schema emitted for taplo completion (`perch config --emit-schema`),
        // so the two never drift. PerchCore reads config via
        // `Toml.parseFlat` (the flat, lenient skin); the multi-line
        // `[behavior].roles` array that the old single-line parser
        // silently skipped now parses correctly. The adapter resolves the
        // spec to NSColors itself (perch keeps its own `[overlay].accent`
        // override + pill-surface treatment), so it does NOT link
        // PaletteKit. Since 1.10.0 the adapter DOES link `Effects` — sill's
        // shared dynamic-theming atom — so the overlay's animated neon
        // border stops re-implementing facet's `[border]` hue table and
        // shares ONE border vocabulary with the family (see the
        // PerchAdapterMacOS target dep below). Pinned to a SemVer tag for
        // release/CI reproducibility; `.upToNextMinor` keeps it on a single
        // minor (a sill minor can still break, so don't auto-jump). Floor
        // 1.10.0 = the release whose `Effects` module ships the border
        // animator perch adopts here; it also clears the older 0.11.0 floor
        // (sill removing its in-tree `Toml`, moved to the standalone
        // swift-toml-edit repo below) and the `CLIKit` module — the
        // family's shared pure argv tokenizer (atelier Phase 3 M3). PerchApp consumes CLIKit so the yabai-style `perch
        // <domain> --<verb> VALUE` grammar gets arity-driven value consumption
        // (negative coords, `--theme ''` empty-clear, loud unknown-flag exit
        // 2) for free, replacing perch's old flat `argv.contains` parser. For
        // local, atomic sill↔perch editing, temporarily swap this line for
        // `.package(path: "../sill")`.
        .package(url: "https://github.com/akira-toriyama/sill.git",
                 .upToNextMinor(from: "1.12.0")),
        // swift-toml-edit — the family's ONE TOML implementation (Sill-1).
        // Provides the `Toml` module PerchCore reads config with
        // (`Toml.parseFlat`); the module name is unchanged so `import Toml`
        // survives. Lives in its own repo since sill 0.11.0.
        .package(url: "https://github.com/akira-toriyama/swift-toml-edit.git",
                 .upToNextMinor(from: "1.0.0")),
    ],
    targets: [
        .target(
            name: "PerchCore",
            dependencies: [
                .product(name: "Palette", package: "sill"),
                .product(name: "Toml", package: "swift-toml-edit"),
                // ConfigSchema: one declarative `Spec` drives BOTH the
                // config.toml decode and the JSON Schema emitted for taplo
                // completion (`perch config --emit-schema`) — so the two never drift.
                .product(name: "ConfigSchema", package: "sill"),
            ]),
        .target(
            name: "PerchAdapterMacOS",
            dependencies: [
                "PerchCore",
                .product(name: "Palette", package: "sill"),
                // Effects: sill's shared dynamic-theming atom. The overlay's
                // animated neon border resolves through Effects' `EffectSpec`
                // catalog + the pure `resolveBorder` (perch stays the
                // redraw-clock owner + NSColor materializer + glow compositor
                // — sill's app-side border contract), replacing perch's own
                // hand-rolled hue-rotation table. The pure half is
                // Sendable/no-AppKit; the @MainActor drawing half is consumed
                // ONLY here in the AppKit adapter, so PerchCore stays
                // AppKit-free.
                .product(name: "Effects", package: "sill"),
                // PaletteKit: sill's @MainActor theme RESOLVER (ROADMAP #5).
                // `HintPainter.resolvePalette` now hands the chosen `ThemeSpec`
                // to `PaletteKit.resolve`, which materialises every role
                // (foreground / error / the system-primary sentinel →
                // controlAccentColor) as an `NSColor`, replacing perch's
                // hand-rolled `color(hex:)` math. perch keeps ONLY the two
                // overlays sill doesn't model — the translucent pill surface
                // and the per-app accent override. Also supplies the shared
                // sRGB `NSColor(hex:)` used by the particle/search canvases.
                // AppKit-side, so consumed ONLY here in the adapter; PerchCore
                // stays pure (depends on `Palette` alone).
                .product(name: "PaletteKit", package: "sill"),
            ]),
        .target(name: "PerchAdapterTest", dependencies: ["PerchCore"]),
        .executableTarget(
            name: "PerchApp",
            dependencies: [
                "PerchCore",
                "PerchAdapterMacOS",
                // CLIKit: the family's shared pure argv tokenizer (atelier
                // Phase 3). Drives the yabai-style `perch <domain> --<verb>
                // VALUE` grammar — arity-driven value consumption (so
                // `--theme ''` clears the override and a `-`-leading theme
                // name isn't mistaken for a flag) + loud unknown-flag exit 2.
                // perch keeps its OWN verb vocabulary + dispatch policy
                // (reject-before-act ordering); CLIKit only tokenizes.
                .product(name: "CLIKit", package: "sill"),
            ]),
        .testTarget(
            name: "PerchCoreTests",
            dependencies: [
                "PerchCore",
                .product(name: "Palette", package: "sill"),
            ]),
        // Drives the synthetic UIElementSource end-to-end through Core's
        // label assignment + match resolution — the real consumer of
        // PerchAdapterTest that the docs describe.
        .testTarget(
            name: "PerchIntegrationTests",
            dependencies: ["PerchCore", "PerchAdapterTest"]),
        // Tests of the pure-mapping bits of the macOS adapter
        // (e.g. `HotkeyMonitor.keyCode(for:)`). The system-bound
        // parts (AXSource walks, KeyTap install, overlay rendering)
        // can't be unit-tested without a live display + AX grant —
        // those stay verified manually via `./run.sh` + the
        // diagnostic log lines. Keep this target around as the
        // landing pad for any future adapter logic that's
        // testable in isolation.
        .testTarget(
            name: "PerchAdapterMacOSTests",
            dependencies: [
                "PerchAdapterMacOS",
                // BorderEffectMappingTests asserts perch's `BorderEffect`
                // case names still resolve in sill's shared `Effects`
                // catalog (`borderEffectFor`) after the 1.10 convergence.
                "PerchCore",
                .product(name: "Effects", package: "sill"),
                // PaletteResolveMappingTests pins the sill-PaletteKit colour
                // convergence (ROADMAP #5): `resolvePalette` reads sill's
                // resolved roles + sentinel and layers perch's accent override.
                .product(name: "PaletteKit", package: "sill"),
            ]),
    ]
)

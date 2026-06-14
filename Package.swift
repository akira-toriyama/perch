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
        // the `Toml` module — the family's ONE hand-rolled TOML subset
        // parser (perch's in-tree TOML.swift folded into sill in atelier
        // Phase 1.6) — and, since 0.9.0, the `ConfigSchema` module: one
        // declarative `Spec` drives BOTH the config.toml decode and the
        // JSON Schema emitted for taplo completion (`perch --emit-schema`),
        // so the two never drift. PerchCore reads config via
        // `Toml.parseFlat` (the flat, lenient skin); the multi-line
        // `[behavior].roles` array that the old single-line parser
        // silently skipped now parses correctly. The adapter resolves the
        // spec to NSColors itself (perch keeps its own `[overlay].accent`
        // override + pill-surface treatment), so it does NOT link
        // PaletteKit. Pinned to a SemVer tag for release/CI
        // reproducibility; `.upToNextMinor` keeps it on a single pre-1.0
        // minor (a pre-1.0 minor can break, so don't auto-jump). Floor
        // 0.9.0 = the `ConfigSchema` module. For local, atomic sill↔perch
        // editing, temporarily swap this line for `.package(path: "../sill")`.
        .package(url: "https://github.com/akira-toriyama/sill.git",
                 .upToNextMinor(from: "0.9.1")),
    ],
    targets: [
        .target(
            name: "PerchCore",
            dependencies: [
                .product(name: "Palette", package: "sill"),
                .product(name: "Toml", package: "sill"),
                // ConfigSchema: one declarative `Spec` drives BOTH the
                // config.toml decode and the JSON Schema emitted for taplo
                // completion (`perch --emit-schema`) — so the two never drift.
                .product(name: "ConfigSchema", package: "sill"),
            ]),
        .target(
            name: "PerchAdapterMacOS",
            dependencies: [
                "PerchCore",
                .product(name: "Palette", package: "sill"),
            ]),
        .target(name: "PerchAdapterTest", dependencies: ["PerchCore"]),
        .executableTarget(
            name: "PerchApp",
            dependencies: [
                "PerchCore",
                "PerchAdapterMacOS",
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
            dependencies: ["PerchAdapterMacOS"]),
    ]
)

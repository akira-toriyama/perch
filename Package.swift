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
    targets: [
        .target(name: "PerchCore"),
        .target(name: "PerchAdapterMacOS", dependencies: ["PerchCore"]),
        .target(name: "PerchAdapterTest", dependencies: ["PerchCore"]),
        .executableTarget(
            name: "PerchApp",
            dependencies: [
                "PerchCore",
                "PerchAdapterMacOS",
            ]),
        .testTarget(name: "PerchCoreTests", dependencies: ["PerchCore"]),
        // Drives the synthetic UIElementSource end-to-end through Core's
        // label assignment + match resolution — the real consumer of
        // PerchAdapterTest that the docs describe.
        .testTarget(
            name: "PerchIntegrationTests",
            dependencies: ["PerchCore", "PerchAdapterTest"]),
    ]
)

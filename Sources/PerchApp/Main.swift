// Entry point. Three modes chosen by CLI flag: server (no flag —
// install hotkey, wait), client (`--reload` / `--quit` — post DNC
// to the running server), standalone (`--validate` / `--doctor` /
// `--help`).
//
// `@main enum PerchApp` — NOT top-level `main.swift`. The enum form
// lets a future XCTest `@testable import PerchApp` work without
// launching the daemon (same trap as stroke / facet / ws-tabs —
// don't reintroduce main.swift).

import AppKit
import Foundation
import PerchCore
import PerchAdapterMacOS

@main
enum PerchApp {

    static func printHelp() -> Never {
        let help = """
        perch — keyboard-driven UI navigator for macOS.

        USAGE
          perch                       run as agent (waits for hotkey)
          perch [COMMAND]             one-shot client command

        SERVER MODE
          perch                       run as agent
          perch --debug               verbose log to stderr +
                                      /tmp/perch.log

        CLIENT COMMANDS — need a running daemon (exit 3 if none)
          perch --activate            show hint overlay now (alt. to hotkey)
          perch --scroll              enter scroll mode (j/k/d/u/gg/G, esc)
          perch --cancel              dismiss the overlay if showing
          perch --reload              re-read ~/.config/perch/config.toml
          perch --status              print active hotkey, alphabet, last event
          perch --quit                terminate the running daemon

        STANDALONE COMMANDS — no daemon required
          perch --validate            parse config.toml; exit 0 if valid
          perch --doctor              health check: Accessibility, config,
                                      daemon, hotkey
          perch --help                this help

        EXIT CODES
          0   success
          2   bad flag / invalid config
          3   precondition mismatch: client cmd with no daemon

        CONFIG
          ~/.config/perch/config.toml is the single source of truth.
          perch never writes to it.

        DOCS
          https://github.com/akira-toriyama/perch
        """
        print(help)
        exit(0)
    }

    static func main() {
        let argv = Array(CommandLine.arguments.dropFirst())

        if argv.contains("--help") { printHelp() }
        if argv.contains("--debug") { debugMode = true }

        // Two-pass: reject ANY unknown flag *before* dispatching a
        // recognised one, so `perch --reload --typo` fails loudly on
        // --typo instead of silently acting on --reload and never
        // looking at the rest (no silent fallback — facet/stroke
        // Rule of Repair discipline).
        let recognised: Set<String> = [
            "--help", "--debug", "--validate", "--doctor",
            "--activate", "--cancel", "--scroll",
            "--reload", "--quit", "--status",
        ]
        for a in argv where !recognised.contains(a) {
            let msg = "perch: unknown flag \"\(a)\" — see "
                + "`perch --help`\n"
            FileHandle.standardError.write(Data(msg.utf8))
            exit(2)
        }

        // Standalone modes — no running daemon required.
        if argv.contains("--doctor") { runDoctor() }
        if argv.contains("--validate") {
            let cfg = PerchConfig.load()
            FileHandle.standardError.write(Data((
                "perch: loaded hotkey=\(human(cfg.hotkey)), "
                + "alphabet=\"\(cfg.alphabet)\", "
                + "\(cfg.roles.count) role(s)\n"
            ).utf8))
            exit(0)
        }

        // Client commands — require a running daemon.
        if argv.contains("--status")   { runStatus() }
        if argv.contains("--activate") { runClient(cmd: "activate") }
        if argv.contains("--scroll")   { runClient(cmd: "scroll") }
        if argv.contains("--cancel")   { runClient(cmd: "cancel") }
        if argv.contains("--reload")   { runClient(cmd: "reload") }
        if argv.contains("--quit")     { runClient(cmd: "quit") }

        // ----- Server mode -----
        runServer()
    }

    @MainActor
    private static func runServer() -> Never {
        let cfg = PerchConfig.load()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)            // LSUIElement: no Dock icon
        AXTrust.ensureTrusted()

        let controller = Controller(config: cfg)
        controller.start()

        Log.line("perch: server running, hotkey=\(human(cfg.hotkey))")
        app.run()
        exit(0)
    }

    /// Health report: Accessibility, config, daemon. Exit 0 if
    /// everything's green, 1 if any check fails.
    private static func runDoctor() -> Never {
        func line(_ ok: Bool, _ label: String, _ detail: String) -> String {
            "  \(ok ? "✓" : "✗")  \(label.padding(toLength: 16, withPad: " ", startingAt: 0))\(detail)"
        }
        var ok = true
        print("perch doctor")

        let ax = AXTrust.isTrusted()
        ok = ok && ax
        print(line(ax, "Accessibility:",
                   ax ? "granted"
                      : "NOT granted — open Perch.app and grant it in "
                        + "System Settings → Privacy & Security → Accessibility"))

        let fileExists = FileManager.default.fileExists(atPath: PerchConfig.path)
        let cfg = PerchConfig.load()
        print(line(fileExists, "Config:",
                   fileExists
                     ? "\(PerchConfig.path) — hotkey=\(human(cfg.hotkey)), "
                       + "\(cfg.roles.count) role(s)"
                     : "no file at \(PerchConfig.path) — using built-in "
                       + "defaults (curl the template)"))

        let running = isServerRunning()
        print(line(running, "Daemon:",
                   running ? "running" : "not running — start with `perch`"))

        print(line(true, "Hotkey:", human(cfg.hotkey)))
        print(line(true, "Alphabet:",
                   "\"\(cfg.alphabet)\" (\(cfg.alphabet.count) chars)"))
        if !cfg.excludeApps.isEmpty {
            print(line(true, "Excludes:",
                       cfg.excludeApps.joined(separator: ", ")))
        }
        exit(ok ? 0 : 1)
    }

    /// Print the running daemon's status from the status file it
    /// maintains. Exit 3 if no daemon is running.
    private static func runStatus() -> Never {
        guard isServerRunning() else {
            FileHandle.standardError.write(Data((
                "perch: --status needs a running daemon. Start one "
                + "with `perch` first.\n"
            ).utf8))
            exit(3)
        }
        if let s = try? String(contentsOfFile: statusPath, encoding: .utf8) {
            print(s)
        } else {
            print("perch: running (status file not written yet)")
        }
        exit(0)
    }

    /// Post `cmd` to the running daemon via DistributedNotificationCenter,
    /// then exit. Refuses (exit 3) if no daemon is running so the
    /// user doesn't get a silent no-op.
    private static func runClient(cmd: String) -> Never {
        guard isServerRunning() else {
            FileHandle.standardError.write(Data((
                "perch: no daemon running — start it with "
                + "`perch` (or `perch --debug`) first\n"
            ).utf8))
            exit(3)
        }
        DistributedNotificationCenter.default().postNotificationName(
            .init(controlNotificationName),
            object: cmd,
            userInfo: nil,
            deliverImmediately: true
        )
        exit(0)
    }

    /// `true` when another perch server process is currently
    /// running. Uses `pgrep` (part of macOS — no extra deps).
    /// Self-aware: this process's own pid is excluded so a
    /// client-mode invocation doesn't mis-detect itself.
    private static func isServerRunning() -> Bool {
        let myPid = ProcessInfo.processInfo.processIdentifier
        let patterns = ["/Contents/MacOS/perch", "\\.build/.*/perch"]
        for pattern in patterns {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-f", pattern]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                return true     // can't tell — assume alive
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let text = String(data: data, encoding: .utf8)
            else { continue }
            let pids = text.split(separator: "\n")
                .compactMap { Int32($0) }
            if pids.contains(where: { $0 != myPid }) { return true }
        }
        return false
    }

    private static func human(_ combo: HotkeyCombo) -> String {
        var parts: [String] = []
        if combo.modifiers.contains(.ctrl)  { parts.append("ctrl") }
        if combo.modifiers.contains(.alt)   { parts.append("alt") }
        if combo.modifiers.contains(.shift) { parts.append("shift") }
        if combo.modifiers.contains(.cmd)   { parts.append("cmd") }
        parts.append(combo.key)
        return parts.joined(separator: "+")
    }
}

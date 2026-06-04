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
                                      (set PERCH_DEBUG=1 in the
                                      environment for a verbose log to
                                      stderr + /tmp/perch.log)

        CLIENT COMMANDS — need a running daemon (exit 3 if none)
          perch --activate            show hint overlay now (alt. to hotkey)
          perch --scroll              enter scroll mode (j/k/d/u/gg/G, esc)
          perch --search              enter search mode (type, then 1-9 to pick)
          perch --regional            enter regional mode — label large
                                      containers (article / pane / image)
                                      instead of every clickable leaf
          perch --cancel              dismiss the overlay if showing
          perch --reload              re-read ~/.config/perch/config.toml
          perch --status              print active hotkey, alphabet, last event
          perch --quit                terminate the running daemon

        STANDALONE COMMANDS — no daemon required
          perch --validate            parse config.toml; exit 0 if valid
          perch --doctor              health check: Accessibility, config,
                                      daemon, hotkey, screens, log file
          perch --dump-ax             dump AX elements perch would label
                                      in the current frontmost app
                                      (one line per element; useful for
                                      "why isn't this element labelled?"
                                      triage)
          perch --dump-ax-tree        dump the raw AX tree (depth-first,
                                      pre-filter) of the frontmost app's
                                      focused window — useful when an
                                      element doesn't even reach the
                                      filter chain (web view content
                                      hidden by lazy AX backends, etc.)
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
        if ProcessInfo.processInfo.environment["PERCH_DEBUG"] != nil {
            debugMode = true
        }

        // Two-pass: reject ANY unknown flag *before* dispatching a
        // recognised one, so `perch --reload --typo` fails loudly on
        // --typo instead of silently acting on --reload and never
        // looking at the rest (no silent fallback — facet/stroke
        // Rule of Repair discipline).
        let recognised: Set<String> = [
            "--help", "--validate", "--doctor",
            "--dump-ax", "--dump-ax-tree",
            "--activate", "--cancel", "--scroll", "--search",
            "--regional",
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
        if argv.contains("--dump-ax-tree") { runDumpAXTree() }
        if argv.contains("--dump-ax") { runDumpAX() }
        if argv.contains("--validate") {
            let cfg = PerchConfig.load()
            // Per-app override count is the at-a-glance signal that
            // `[behavior."<bundle>"]` sections parsed — issue #37's
            // acceptance criterion. Empty for the common case so we
            // don't noise up the line; surfaces only when configured.
            let perApp = cfg.perApp.isEmpty
                ? ""
                : ", \(cfg.perApp.count) per-app override(s)"
            FileHandle.standardError.write(Data((
                "perch: loaded hotkey=\(human(cfg.hotkey)), "
                + "alphabet=\"\(cfg.alphabet)\", "
                + "\(cfg.roles.count) role(s)\(perApp)\n"
            ).utf8))
            exit(0)
        }

        // Client commands — require a running daemon.
        if argv.contains("--status")   { runStatus() }
        if argv.contains("--activate") { runClient(cmd: "activate") }
        if argv.contains("--scroll")   { runClient(cmd: "scroll") }
        if argv.contains("--search")   { runClient(cmd: "search") }
        if argv.contains("--regional") { runClient(cmd: "regional") }
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

    /// Health report: Accessibility, config, daemon, screen layout,
    /// log file. Exit 0 if everything's green, 1 if any check
    /// fails. Every line is also useful information for a bug
    /// report; copying the entire `perch --doctor` output is the
    /// single most useful attachment for triage.
    private static func runDoctor() -> Never {
        func line(_ ok: Bool, _ label: String, _ detail: String) -> String {
            "  \(ok ? "✓" : "✗")  \(label.padding(toLength: 16, withPad: " ", startingAt: 0))\(detail)"
        }
        func info(_ label: String, _ detail: String) -> String {
            "  ·  \(label.padding(toLength: 16, withPad: " ", startingAt: 0))\(detail)"
        }
        var ok = true
        print("perch doctor")

        // Environment first — establishes what platform the rest of
        // the checks are running against.
        let osVer = ProcessInfo.processInfo.operatingSystemVersionString
        print(info("macOS:", osVer))

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

        print(info("Hotkey:", human(cfg.hotkey)))
        print(info("Cancel key:", "\"\(cfg.cancelKey)\""))
        print(info("Alphabet:",
                   "\"\(cfg.alphabet)\" (\(cfg.alphabet.count) chars)"))
        if !cfg.excludeApps.isEmpty {
            print(info("Excludes:",
                       cfg.excludeApps.joined(separator: ", ")))
        }
        // List per-app overrides (#37) when configured — the
        // single most actionable triage line for "why does perch
        // behave differently in Chrome vs Slack?".
        if !cfg.perApp.isEmpty {
            print(info("Per-app:",
                       cfg.perApp.keys.sorted().joined(separator: ", ")))
        }

        // Screen layout — a frequent cause of "why are the pills
        // showing up nowhere?" reports is an unexpected multi-
        // monitor topology, so spell it out.
        let screens = NSScreen.screens
        print(info("Screens:", "\(screens.count) connected"))
        for (i, s) in screens.enumerated() {
            let marker = (s == NSScreen.main) ? " (main)" : ""
            print(info("  screen \(i):",
                       "\(Int(s.frame.minX)),\(Int(s.frame.minY)) "
                       + "\(Int(s.frame.width))×\(Int(s.frame.height))"
                       + marker))
        }

        // Frontmost app — the target perch would walk if you
        // pressed shift+space right now. Often the missing piece
        // when reproducing a bug ("oh, perch saw loginwindow, not
        // Chrome").
        if let front = NSWorkspace.shared.frontmostApplication {
            let bid = front.bundleIdentifier ?? "<no bundle id>"
            print(info("Frontmost:",
                       "\(bid) (pid \(front.processIdentifier))"))
        } else {
            print(info("Frontmost:", "(none — no app currently frontmost)"))
        }

        // Log file — exists / size + a hint for where to look.
        let logPath = Log.path
        if let attrs = try? FileManager.default
                .attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? Int {
            print(info("Log:", "\(logPath) (\(size) bytes)"))
        } else {
            print(info("Log:", "\(logPath) (not yet created)"))
        }

        exit(ok ? 0 : 1)
    }

    /// Dump every AX element perch's filter chain would label in
    /// the current frontmost app. One line per element; the format
    /// matches what `PERCH_DEBUG=1` would log per walk but the
    /// standalone path doesn't need the daemon running.
    ///
    /// Useful when answering "why isn't <button X> being labeled?"
    /// — if `--dump-ax` shows the element, the bug is in label
    /// assignment / overlay rendering; if it doesn't, the bug is
    /// in the AX walk / filter chain (then re-run with `PERCH_DEBUG=1`
    /// for per-stage drop reasons).
    @MainActor
    private static func runDumpAX() -> Never {
        guard AXTrust.isTrusted() else {
            FileHandle.standardError.write(Data((
                "perch: Accessibility not granted — grant it to perch "
                + "(or to the bundled Perch.app) in System Settings → "
                + "Privacy & Security → Accessibility, then re-run.\n"
            ).utf8))
            exit(1)
        }
        guard let front = NSWorkspace.shared.frontmostApplication else {
            FileHandle.standardError.write(Data((
                "perch: no frontmost app — focus the window you want "
                + "to inspect, then re-run.\n"
            ).utf8))
            exit(1)
        }
        let bid = front.bundleIdentifier ?? "<no bundle id>"
        print("perch dump-ax → \(bid) (pid \(front.processIdentifier))")

        let cfg = PerchConfig.load()
        let source = AXUIElementSource(config: cfg)
        let elements = source.enumerate()
        print("found \(elements.count) labelable element(s):")
        for (i, e) in elements.enumerated() {
            let label = e.label.isEmpty
                ? "<no title>"
                : "\"\(e.label.prefix(60))\""
            let f = e.frame
            // Use Swift interpolation, not `String(format: "%-15s %@", …)`
            // — passing Swift String to NSString's `%s` / `%@` via
            // CVarArg is undefined and segfaults at runtime on a
            // non-empty result list (caught on a 184-element Chrome
            // dump after the renderer-AX wake landed).
            let num = String(format: "%3d", i + 1)
            let role = e.role.padding(
                toLength: 15, withPad: " ", startingAt: 0)
            let pos = String(format: "(%5d,%5d %4d×%4d)",
                             Int(f.minX), Int(f.minY),
                             Int(f.width), Int(f.height))
            print("  \(num)  \(role)  \(pos)  \(label)")
        }
        exit(0)
    }

    /// Dump the raw AX tree of the frontmost app's focused window
    /// (pre-filter — no role allow-list, no press-support check, no
    /// window-bounds clamp). Sibling of `--dump-ax` for the case
    /// where the element doesn't even reach the filter chain (most
    /// often: a web view whose AX content the backend hasn't
    /// awakened, or a node living below the native walker's depth
    /// cap). The output is intentionally verbose so a maintainer
    /// can compare a Chrome dump against a native one and spot
    /// what's missing.
    @MainActor
    private static func runDumpAXTree() -> Never {
        guard AXTrust.isTrusted() else {
            FileHandle.standardError.write(Data((
                "perch: Accessibility not granted — grant it to perch "
                + "(or to the bundled Perch.app) in System Settings → "
                + "Privacy & Security → Accessibility, then re-run.\n"
            ).utf8))
            exit(1)
        }
        var sink = StdoutSink()
        AXDump.dumpRawTree(to: &sink)
        exit(0)
    }

    /// `TextOutputStream` that forwards to stdout. We can't use
    /// `FileHandle.standardOutput` directly as a stream because it
    /// doesn't conform; this is the standard one-shot adapter.
    private struct StdoutSink: TextOutputStream {
        mutating func write(_ s: String) { print(s, terminator: "") }
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
                + "`perch` (or `PERCH_DEBUG=1 perch`) first\n"
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

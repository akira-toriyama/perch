// Entry point. yabai-style `perch <domain> --<verb> [VALUE]` CLI
// (atelier Phase 3 M3). Bare `perch` is server mode (install hotkey,
// wait); every other invocation peels a domain noun and dispatches a
// verb:
//
//   overlay  --activate / --scroll / --search / --regional / --menu /
//            --windows / --emoji / --grid / --rgrid / --nudge / --drag /
//            --vision / --cancel  (mode entry, post DNC to the daemon)
//            --theme <name>       (live theme override modifier)
//   daemon   --reload / --show (was --status) / --quit  (post DNC)
//   config   --validate / --doctor / --emit-schema      (standalone)
//   ax       --dump (was --dump-ax) / --tree (was --dump-ax-tree) /
//            --regions (was --dump-regions)              (standalone)
//
// argv tokenizing is delegated to the family's shared pure `CLIKit`
// tokenizer (sill): it consumes values by app-declared arity, so the
// `--verb=value` form is gone and `--theme ''` (empty-clear) / a
// `-`-leading theme name are taken verbatim instead of mistaken for
// flags. perch keeps its OWN verb vocabulary + reject-before-act
// ordering (parse runs before any DNC post); CLIKit only tokenizes.
// The DNC wire commands (grid / search / theme:<name> / reload / quit /
// …) are unchanged, so the new CLI talks to an old daemon and vice
// versa — only the argv surface moved.
//
// `@main enum PerchApp` — NOT top-level `main.swift`. The enum form
// lets a future XCTest `@testable import PerchApp` work without
// launching the daemon (same trap as stroke / facet / ws-tabs —
// don't reintroduce main.swift).

import AppKit
import Foundation
import CLIKit
import PerchCore
import PerchAdapterMacOS

@main
enum PerchApp {

    static func printHelp() -> Never {
        let help = """
        perch — keyboard-driven UI navigator for macOS.

        USAGE
          perch                              run as agent (waits for hotkey)
          perch <domain> --<verb> [VALUE]   one-shot control command

        SERVER MODE
          perch                             run as agent
                                              (set PERCH_DEBUG=1 in the
                                              environment for a verbose log to
                                              stderr + /tmp/perch.log)

        overlay — hint / mode entry (need a running daemon; exit 3 if none)
          overlay --activate          show hint overlay now (alt. to hotkey)
          overlay --scroll            enter scroll mode (j/k/d/u/gg/G, esc)
          overlay --search            enter search mode (type, then 1-9 to pick)
          overlay --regional          regional mode — label large containers
                                        (article / pane / image) instead of
                                        every clickable leaf
          overlay --menu              menu-search mode — fuzzy search the
                                        frontmost app's whole menu bar (deep /
                                        hidden commands incl.); pick with 1-9
          overlay --windows           cross-app window switcher — fuzzy search
                                        every window across every running app;
                                        pick with 1-9 (raises + activates)
          overlay --emoji             emoji picker — fuzzy search a curated
                                        table by name (thinking → 🤔); 1-9 types
                                        the glyph at the caret (no pasteboard)
          overlay --grid              coordinate grid — divide the screen union
                                        into labeled cells; type label to warp
                                        cursor + left-click (Shift → right-click,
                                        Cmd → warp only). For canvas / custom UI
                                        hint mode can't see.
          overlay --rgrid             recursive grid — each label pick subdivides
                                        the chosen cell up to [grid].max-depth
                                        levels (default 3). Space / Enter clicks
                                        the current cell center; Backspace pops.
          overlay --nudge             arrow-nudge cursor — arrows move 1px (bare),
                                        10px (Shift), 100px (Alt), screen-edge
                                        (Cmd). Space/Enter clicks + exits.
          overlay --drag              keyboard drag — nudge to A, `d` to grab
                                        (mouseDown), nudge to B, `d` to release.
                                        Esc is a safety release.
          overlay --vision            Vision-OCR hint mode — Apple Vision text
                                        recognition on the main display, each
                                        visible word becomes a hint. Requires
                                        Screen Recording grant.
          overlay --cancel            dismiss the overlay if showing
          overlay --theme <name>      live theme override (applies to all
                                        activations until `daemon --reload` or
                                        `overlay --theme ''` clears it). Any
                                        built-in (terminal / dracula /
                                        catppuccin-mocha / ... / system / random)
                                        or an [overlay.themes.<name>] custom.
                                        Compose with a mode verb to apply
                                        immediately:
                                            perch overlay --activate --theme dracula

        daemon — lifecycle (need a running daemon; exit 3 if none)
          daemon --reload             re-read ~/.config/perch/config.toml
          daemon --show               print active hotkey, alphabet, last event
          daemon --quit               terminate the running daemon

        config — settings (no daemon required)
          config --validate           parse config.toml; exit 0 if valid
          config --doctor             health check: Accessibility, config,
                                        daemon, hotkey, screens, log file
          config --emit-schema        print the config.toml JSON Schema
                                        (Draft-07) to stdout. Generated from
                                        perch's own parser, so it always matches
                                        the binary. Regenerate with:
                                          perch config --emit-schema > config.schema.json

        ax — accessibility diagnostics (no daemon required)
          ax --dump                   dump AX elements perch would label in the
                                        current frontmost app (one line each;
                                        "why isn't this element labelled?" triage)
          ax --tree                   dump the raw AX tree (depth-first,
                                        pre-filter) of the frontmost app's
                                        focused window — for when an element
                                        doesn't even reach the filter chain
                                        (web view content hidden by lazy AX, etc.)
          ax --regions                same shape as `ax --dump` but lists what
                                        `perch overlay --regional` would label
                                        (tune `[regional].min-width / min-height`)

          perch --help, -h            this help

        EXIT CODES
          0   success
          1   diagnostic check failed (config --doctor, ax --* with no AX grant)
          2   usage / bad flag / invalid config (loud on stderr)
          3   daemon precondition: a daemon / overlay command with no daemon running

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

        // Debug logging is triggered by the PERCH_DEBUG env var (set by
        // run.sh on the dev bundle), NOT a CLI flag — run.sh and a
        // brew / raw launch start the same artifact, so the signal is
        // injected at launch time. A normal launch sets nothing and
        // stays quiet.
        if ProcessInfo.processInfo.environment["PERCH_DEBUG"] != nil {
            debugMode = true
        }

        // Bare `perch` = server mode (the LSUIElement launch path). Every
        // other invocation is a yabai-style `perch <domain> --<verb>`
        // control command. The domain noun is peeled here; CLIKit then
        // tokenizes the rest against that domain's verb-arity spec.
        guard let domain = argv.first else { runServer() }
        switch domain {
        case "--help", "-h": printHelp()
        case "overlay": dispatchOverlay(Array(argv.dropFirst()))
        case "daemon":  dispatchDaemon(Array(argv.dropFirst()))
        case "config":  dispatchConfig(Array(argv.dropFirst()))
        case "ax":      dispatchAX(Array(argv.dropFirst()))
        default:
            // A `-`-leading first token is almost always an old flat
            // flag (`perch --grid`) — point at the new home loudly
            // instead of a bare "unknown command".
            if domain.hasPrefix("-") {
                CLIKit.die("perch", "flags now live under a domain — e.g. "
                    + "`perch overlay --activate`, `perch daemon --reload`, "
                    + "`perch config --validate`, `perch ax --dump`. "
                    + "Got '\(domain)'. See `perch --help`.")
            }
            CLIKit.die("perch", "unknown command '\(domain)'. Domains: "
                + "overlay daemon config ax (or bare `perch` for server). "
                + "See `perch --help`.")
        }
    }

    // MARK: domain dispatch (CLIKit tokenizes; perch keeps verb policy — D4)

    /// Parse `argv` against `spec`, mapping any usage error to a loud
    /// exit 2. (CLIKit's tokenizer is pure; perch owns the exit, and
    /// — because parse runs before any DNC post — keeps perch's
    /// reject-before-act ordering: a typo never half-fires a command.)
    private static func parseOrDie(_ argv: [String], _ spec: CLIKit.Spec) -> CLIKit.Invocation {
        do { return try CLIKit.parse(argv, spec: spec) }
        catch let e as CLIKit.ParseError { CLIKit.die("perch", e.usageMessage) }
        catch { CLIKit.die("perch", "\(error)") }
    }

    /// Exactly one of `verbs` must be present. CLIKit already rejected
    /// unknown flags; this is perch's mutual-exclusion policy (a domain
    /// has one action; modifiers attach to it).
    private static func requireOneVerb(_ inv: CLIKit.Invocation, among verbs: [String],
                                       domain: String) -> String {
        let present = inv.names.filter { verbs.contains($0) }
        if present.count == 1 { return present[0] }
        if present.isEmpty {
            CLIKit.die("perch", "`perch \(domain)` needs a verb: "
                + verbs.joined(separator: " ") + ". See `perch --help`.")
        }
        CLIKit.die("perch", "`perch \(domain)`: incompatible verbs "
            + present.joined(separator: " ") + " — pick one. See `perch --help`.")
    }

    /// `overlay` — the 13 mode-entry verbs (each posts a bare-noun wire
    /// command the daemon's control observer already understands) plus
    /// the `--theme <name>` modifier. `--theme` is `.value` arity:
    /// `--theme dracula` sets the override, `--theme ''` clears it (posted
    /// as the bare `theme:` the daemon maps to "clear"), bare `--theme`
    /// with no value is a loud missingValue. It composes with a mode
    /// verb — `overlay --activate --theme dracula` re-themes THEN shows, so
    /// the new theme applies immediately — and is also valid standalone.
    private static func dispatchOverlay(_ argv: [String]) -> Never {
        // verb → DNC wire command (the daemon-side names are frozen so
        // the new CLI talks to an old daemon and vice versa).
        let modeWire: [String: String] = [
            "--activate": "activate", "--cancel": "cancel",
            "--scroll": "scroll", "--search": "search",
            "--regional": "regional", "--menu": "menu",
            "--windows": "windows", "--emoji": "emoji",
            "--grid": "grid", "--rgrid": "rgrid",
            "--nudge": "nudge", "--drag": "drag", "--vision": "vision",
        ]
        var arity: [String: CLIKit.Arity] = ["--theme": .value]
        for k in modeWire.keys { arity[k] = .flag }
        let inv = parseOrDie(argv, CLIKit.Spec(arity: arity))

        // `--theme` is non-nil iff present (CLIKit guarantees its value
        // by arity, incl. the empty string for the clear case).
        let themeName = inv.value("--theme")
        let modes = inv.names.filter { modeWire[$0] != nil }
        if modes.count > 1 {
            CLIKit.die("perch", "`perch overlay`: incompatible verbs "
                + modes.joined(separator: " ") + " — pick one. See `perch --help`.")
        }
        if modes.isEmpty && themeName == nil {
            CLIKit.die("perch", "`perch overlay` needs a verb: "
                + modeWire.keys.sorted().joined(separator: " ")
                + " (or `--theme <name>`). See `perch --help`.")
        }

        // Both posts target the same daemon — check liveness once, then
        // post the theme override (if any) before the mode verb so the
        // mode renders with the override already applied.
        requireDaemon()
        if let name = themeName { post("theme:\(name)") }
        if let verb = modes.first { post(modeWire[verb]!) }
        exit(0)
    }

    /// `daemon` — lifecycle verbs posted to the running daemon over DNC.
    /// `--show` is the old `--status` read口 (greppable status file).
    private static func dispatchDaemon(_ argv: [String]) -> Never {
        let spec = CLIKit.Spec(arity: [
            "--reload": .flag, "--show": .flag, "--quit": .flag,
        ])
        let inv = parseOrDie(argv, spec)
        switch requireOneVerb(inv, among: ["--reload", "--show", "--quit"],
                              domain: "daemon") {
        case "--reload": runClient(cmd: "reload")
        case "--show":   runStatus()
        case "--quit":   runClient(cmd: "quit")
        default: preconditionFailure("unreachable: requireOneVerb returned an unlisted verb")
        }
    }

    /// `config` — standalone settings verbs (no daemon required).
    private static func dispatchConfig(_ argv: [String]) -> Never {
        let spec = CLIKit.Spec(arity: [
            "--validate": .flag, "--doctor": .flag, "--emit-schema": .flag,
        ])
        let inv = parseOrDie(argv, spec)
        switch requireOneVerb(inv, among: ["--validate", "--doctor", "--emit-schema"],
                              domain: "config") {
        case "--validate": runValidate()
        case "--doctor":   runDoctor()
        case "--emit-schema":
            // Generated from the same declarative `configSpec` that
            // decodes the config, so editor schema and parser can't drift.
            print(PerchConfig.jsonSchema, terminator: "")
            exit(0)
        default: preconditionFailure("unreachable: requireOneVerb returned an unlisted verb")
        }
    }

    /// `ax` — standalone accessibility-tree diagnostics (no daemon).
    /// Verbs renamed from the old `--dump-ax` / `--dump-ax-tree` /
    /// `--dump-regions`; the greppable OUTPUT format is unchanged.
    @MainActor
    private static func dispatchAX(_ argv: [String]) -> Never {
        let spec = CLIKit.Spec(arity: [
            "--dump": .flag, "--tree": .flag, "--regions": .flag,
        ])
        let inv = parseOrDie(argv, spec)
        switch requireOneVerb(inv, among: ["--dump", "--tree", "--regions"],
                              domain: "ax") {
        case "--dump":    runDumpAX()
        case "--tree":    runDumpAXTree()
        case "--regions": runDumpRegions()
        default: preconditionFailure("unreachable: requireOneVerb returned an unlisted verb")
        }
    }

    /// `config --validate` — parse config.toml and print a one-line
    /// summary to stderr. `load()` is lenient (missing file → defaults,
    /// malformed values → clamped best-effort), so this is a "parsed
    /// summary" report that always exits 0; it never returns the exit 2
    /// the help advertises for genuinely unparseable usage.
    private static func runValidate() -> Never {
        let cfg = PerchConfig.load()
        // Per-app override count is the at-a-glance signal that
        // `[behavior."<bundle>"]` sections parsed — issue #37's
        // acceptance criterion. Empty for the common case so we
        // don't noise up the line; surfaces only when configured.
        let perApp = cfg.behavior.perApp.isEmpty
            ? ""
            : ", \(cfg.behavior.perApp.count) per-app override(s)"
        let synonyms = cfg.search.synonyms.isEmpty
            ? ""
            : ", \(cfg.search.synonyms.count) synonym group(s)"
        FileHandle.standardError.write(Data((
            "perch: loaded hotkey=\(human(cfg.hotkey.active)), "
            + "alphabet=\"\(cfg.labels.alphabet)\", "
            + "\(cfg.behavior.roles.count) role(s)\(perApp)\(synonyms)\n"
        ).utf8))
        exit(0)
    }

    @MainActor
    private static func runServer() -> Never {
        // Refresh the taplo schema sidecar next to the user config so
        // editor completion/validation just works (idempotent; writes
        // only on change, and the ConfigWatcher tracks config.toml — not
        // this sibling — so the write can't trigger a hot-reload).
        // Best-effort: a failure is non-fatal, so it never blocks start.
        PerchConfig.installSchema()

        let cfg = PerchConfig.load()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)            // LSUIElement: no Dock icon
        AXTrust.ensureTrusted()

        let controller = Controller(config: cfg)
        controller.start()

        Log.line("perch: server running, hotkey=\(human(cfg.hotkey.active))")
        app.run()
        exit(0)
    }

    /// Health report: Accessibility, config, daemon, screen layout,
    /// log file. Exit 0 if everything's green, 1 if any check
    /// fails. Every line is also useful information for a bug
    /// report; copying the entire `perch config --doctor` output is the
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
                     ? "\(PerchConfig.path) — hotkey=\(human(cfg.hotkey.active)), "
                       + "\(cfg.behavior.roles.count) role(s)"
                     : "no file at \(PerchConfig.path) — using built-in "
                       + "defaults (curl the template)"))

        let running = isServerRunning()
        print(line(running, "Daemon:",
                   running ? "running" : "not running — start with `perch`"))

        print(info("Hotkey:", human(cfg.hotkey.active)))
        print(info("Cancel key:", "\"\(cfg.hotkey.cancel)\""))
        print(info("Alphabet:",
                   "\"\(cfg.labels.alphabet)\" (\(cfg.labels.alphabet.count) chars)"))
        if !cfg.behavior.excludeApps.isEmpty {
            print(info("Excludes:",
                       cfg.behavior.excludeApps.joined(separator: ", ")))
        }
        // List per-app overrides (#37) when configured — the
        // single most actionable triage line for "why does perch
        // behave differently in Chrome vs Slack?".
        if !cfg.behavior.perApp.isEmpty {
            print(info("Per-app:",
                       cfg.behavior.perApp.keys.sorted().joined(separator: ", ")))
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
    /// — if `ax --dump` shows the element, the bug is in label
    /// assignment / overlay rendering; if it doesn't, the bug is
    /// in the AX walk / filter chain (then re-run with `PERCH_DEBUG=1`
    /// for per-stage drop reasons).
    @MainActor
    private static func runDumpAX() -> Never {
        runDump(label: "dump-ax") { $0.enumerate() }
    }

    /// Mirror of `ax --dump` for regional hint mode (#34). Prints
    /// every container `perch overlay --regional` WOULD label in the
    /// current frontmost app. Useful for triaging the
    /// "is my `[regional].min-width` floor right for this app?"
    /// question without entering the actual overlay.
    @MainActor
    private static func runDumpRegions() -> Never {
        runDump(label: "dump-regions") { $0.enumerateRegions() }
    }

    /// Shared body of `ax --dump` / `ax --regions`. `enumerator`
    /// picks which `UIElementSource` method to call; the rest of
    /// the formatting is identical so the two outputs stay grep-able
    /// in the same way.
    @MainActor
    private static func runDump(
        label: String,
        enumerator: (AXUIElementSource) -> [UIElement]
    ) -> Never {
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
        print("perch \(label) → \(bid) (pid \(front.processIdentifier))")

        let cfg = PerchConfig.load()
        let source = AXUIElementSource(config: cfg)
        let elements = enumerator(source)
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
    /// window-bounds clamp). Sibling of `ax --dump` for the case
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

    /// `perch daemon --show` — print the running daemon's status from the
    /// status file it maintains. Exit 3 if no daemon is running.
    private static func runStatus() -> Never {
        guard isServerRunning() else {
            FileHandle.standardError.write(Data((
                "perch: `daemon --show` needs a running daemon. Start one "
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

    /// Refuse (exit 3) if no daemon is running, so a client command
    /// doesn't become a silent no-op. Shared by the single-shot
    /// `runClient` and `overlay`'s two-post path (theme + mode).
    private static func requireDaemon() {
        guard isServerRunning() else {
            FileHandle.standardError.write(Data((
                "perch: no daemon running — start it with "
                + "`perch` (or `PERCH_DEBUG=1 perch`) first\n"
            ).utf8))
            exit(3)
        }
    }

    /// Post one control command to the running daemon over
    /// DistributedNotificationCenter. Does NOT exit (the caller decides
    /// when to exit, since `overlay` may post two: theme then mode).
    private static func post(_ cmd: String) {
        DistributedNotificationCenter.default().postNotificationName(
            .init(controlNotificationName),
            object: cmd,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    /// Post a single `cmd` to the running daemon, then exit. Refuses
    /// (exit 3) if no daemon is running.
    private static func runClient(cmd: String) -> Never {
        requireDaemon()
        post(cmd)
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

// Orchestrator. Owns the hotkey monitor, AX source, overlay, and
// the live config snapshot. The hotkey trampoline (Carbon callback,
// also `perch --activate` over DNC) lands on `activate()`, which
// runs the full flow:
//   1. source.enumerate()         AX walk in the adapter
//   2. Labeler.assign → hints     pure logic in Core
//   3. overlay.show(hints)        installs KeyTap (CGEventTap),
//                                  paints panel, returns immediately
//                                  — keypresses come back via the
//                                  onResolve / onCancel callbacks
//   4. on resolve → source.press(id:)  AXUIElementPerformAction

import AppKit
import CoreGraphics
import Foundation
import PerchCore
import PerchAdapterMacOS

@MainActor
final class Controller {

    private(set) var config: PerchConfig
    private let source: AXUIElementSource
    private let overlay: OverlayWindow
    // Created in `start()` because the callback captures `self` — a
    // self-capturing closure can't be passed during the initializer
    // (Swift forbids accessing self before all stored properties are
    // set). Holding it as Optional keeps the type checker happy and
    // matches its lifecycle (only set while the daemon is running).
    private var hotkey: HotkeyMonitor?
    private var active = false
    /// Set when scroll mode owns the KeyTap. Hint mode and scroll
    /// mode are mutually exclusive — Controller tears the other
    /// down before starting either.
    private var scroll: ScrollMode?

    init(config: PerchConfig) {
        self.config = config
        self.source = AXUIElementSource(config: config)
        self.overlay = OverlayWindow(config: config)
    }

    func start() {
        // The hotkey callback is @Sendable + nonisolated (Carbon
        // dispatches it from the main thread but Swift 6 sees it as
        // task-isolated). Hop explicitly onto the main actor so the
        // @MainActor-isolated `activate()` is callable.
        let monitor = HotkeyMonitor { [weak self] in
            Task { @MainActor in self?.activate() }
        }
        monitor.install(combo: config.hotkey)
        self.hotkey = monitor
        installControlObserver()
        writeStatus(reason: "start")
        Log.line("controller: started")
    }

    func reload(cause: String) {
        Log.line("config: reloading (\(cause))")
        let new = PerchConfig.load()
        let hotkeyChanged = new.hotkey != config.hotkey
        config = new
        source.updateConfig(new)
        overlay.updateConfig(new)
        if hotkeyChanged {
            hotkey?.install(combo: new.hotkey)
        }
        writeStatus(reason: "reload")
    }

    // MARK: - Hot flow

    /// Programmatic cancel — used by the `--cancel` IPC command.
    /// Tears down whichever mode owns the KeyTap (hint OR scroll).
    /// Idempotent; no-op when nothing is active.
    func cancel() {
        if active {
            overlay.hide()
            active = false
        }
        if let s = scroll {
            s.stop()
            scroll = nil
        }
    }

    /// Enter scroll mode. Mutually exclusive with hint mode — if
    /// hint mode is up, we tear it down first. `--scroll` invoked
    /// while already in scroll mode exits (symmetric with
    /// `--activate`).
    func enterScrollMode() {
        if active {
            overlay.hide()
            active = false
        }
        if scroll != nil {
            scroll?.stop()
            scroll = nil
            return
        }
        let sm = ScrollMode(cancelKey: config.cancelKey) { [weak self] in
            Task { @MainActor [weak self] in self?.scroll = nil }
        }
        if sm.start() {
            scroll = sm
            writeStatus(reason: "scroll mode")
        }
    }

    private func activate() {
        if let s = scroll {
            // Hint and scroll are mutually exclusive. Activating
            // hint mode while scroll mode is up tears scroll down
            // first so the KeyTap installs cleanly.
            s.stop()
            scroll = nil
        }
        if active {
            // Second hotkey press while up: cancel.
            overlay.hide()
            active = false
            return
        }
        let elements = source.enumerate()
        guard !elements.isEmpty else {
            Log.line("activate: no labelable elements — dismissing")
            return
        }
        let screen = NSScreen.main?.frame.size ?? .zero
        let hints = Labeler.assign(
            elements: elements,
            alphabet: config.alphabet,
            prioritiseCenter: config.prioritiseCenter,
            screenSize: screen)
        active = true
        Log.line("activate: \(hints.count) hint(s)")
        overlay.show(
            hints: hints,
            onResolve: { [weak self] hint, action in
                guard let self else { return }
                self.active = false
                _ = self.source.act(id: hint.element.id, as: action)
                self.writeStatus(
                    reason: "fired \(hint.keys) (\(action.rawValue))")
            },
            onCancel: { [weak self] in
                self?.active = false
                Log.debug("overlay: cancelled")
            })
    }

    // MARK: - IPC

    private func installControlObserver() {
        // The notification block runs on `.main` (an OperationQueue),
        // which is NOT the same as the main actor under Swift 6's
        // model. Hop explicitly so `reload(cause:)` is callable.
        DistributedNotificationCenter.default().addObserver(
            forName: .init(controlNotificationName),
            object: nil,
            queue: .main
        ) { [weak self] note in
            let cmd = note.object as? String ?? ""
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch cmd {
                case "reload":
                    self.reload(cause: "ipc")
                case "activate":
                    // Same entry point the hotkey trampoline calls.
                    // Symmetric: a second --activate while overlay is
                    // up cancels (matches Carbon hotkey behaviour).
                    Log.line("controller: --activate received")
                    self.activate()
                case "cancel":
                    // Tear down the overlay if it's up; no-op otherwise.
                    Log.line("controller: --cancel received")
                    self.cancel()
                case "scroll":
                    Log.line("controller: --scroll received")
                    self.enterScrollMode()
                case "quit":
                    Log.line("controller: --quit received, exiting")
                    exit(0)
                default:
                    Log.line("controller: unknown ipc command \"\(cmd)\"")
                }
            }
        }
    }

    private func writeStatus(reason: String) {
        let text = """
        perch: running
        hotkey: \(human(config.hotkey))
        alphabet: \(config.alphabet)
        roles: \(config.roles.count)
        excludes: \(config.excludeApps.count)
        last: \(reason) @ \(Date())
        """
        try? text.write(
            toFile: statusPath, atomically: true, encoding: .utf8)
    }

    private func human(_ combo: HotkeyCombo) -> String {
        var parts: [String] = []
        if combo.modifiers.contains(.ctrl)  { parts.append("ctrl") }
        if combo.modifiers.contains(.alt)   { parts.append("alt") }
        if combo.modifiers.contains(.shift) { parts.append("shift") }
        if combo.modifiers.contains(.cmd)   { parts.append("cmd") }
        parts.append(combo.key)
        return parts.joined(separator: "+")
    }
}

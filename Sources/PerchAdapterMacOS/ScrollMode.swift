// Keyboard-driven scrolling. Once entered (via `perch --scroll`),
// perch installs a KeyTap that intercepts a small set of vim-style
// keys and synthesises the corresponding `CGEvent` scroll-wheel
// events against the frontmost window — same way every browser
// keyboard-nav extension wires up scroll. macOS dispatches the
// synthesised event to whichever window has focus, so perch can
// stay headless / non-active throughout.
//
// Bindings:
//   j   scroll DOWN  by one notch  (≈ 50 px)
//   k   scroll UP    by one notch
//   d   scroll DOWN  by half a screen height
//   u   scroll UP    by half a screen height
//   gg  scroll to top (g pressed twice in succession)
//   G   scroll to bottom (Shift+g)
//   esc exit scroll mode
//   any other key → exit scroll mode and let the key through
//
// `gg` / `G` go top / bottom by sending many large scroll deltas
// because there's no AX "scroll to extreme" verb that works
// reliably across native apps; the wheel event is the lowest
// common denominator.

import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import PerchCore

@MainActor
public final class ScrollMode {

    private var keyTap: KeyTap?
    private var cancelKeyCode: CGKeyCode = 53        // Esc by default
    private var lastG: TimeInterval?                 // for the gg chord
    private let onExit: () -> Void

    private static let notch: Int32 = 50
    private static let chordWindow: TimeInterval = 0.5

    public init(cancelKey: String, onExit: @escaping () -> Void) {
        self.cancelKeyCode = Self.resolveCancelKeyCode(cancelKey)
        self.onExit = onExit
    }

    /// Install the tap and begin intercepting. Returns `false` and
    /// fires `onExit` immediately if the tap can't be installed
    /// (missing AX grant).
    @discardableResult
    public func start() -> Bool {
        guard keyTap == nil else { return true }
        let tap = KeyTap { [weak self] keyCode, flags, char in
            guard let self else { return false }
            return MainActor.assumeIsolated {
                self.handle(keyCode: keyCode, flags: flags, char: char)
            }
        }
        guard tap.install() else {
            Log.line("scroll: keytap install failed — bailing")
            onExit()
            return false
        }
        keyTap = tap
        Log.line("scroll: mode entered")
        return true
    }

    public func stop() {
        keyTap?.uninstall()
        keyTap = nil
        lastG = nil
        Log.line("scroll: mode exited")
    }

    // MARK: - Key handling

    /// Returns `true` to swallow the keypress, `false` to let it
    /// through. Esc + the recognised motion keys swallow; anything
    /// else exits scroll mode and lets the key through so the user
    /// isn't stuck.
    private func handle(
        keyCode: CGKeyCode, flags: CGEventFlags, char: String
    ) -> Bool {
        // Esc — exit silently.
        if keyCode == cancelKeyCode {
            stop()
            onExit()
            return true
        }
        // Ctrl-anything → exit + let through, so the user's
        // system shortcuts keep working.
        if flags.contains(.maskControl) {
            stop()
            onExit()
            return false
        }

        let ch = char.first
        let shift = flags.contains(.maskShift)
        switch ch {
        case "j":
            scroll(by: -Self.notch); return true
        case "k":
            scroll(by: Self.notch); return true
        case "d":
            scroll(by: -Self.halfScreenHeight()); return true
        case "u":
            scroll(by: Self.halfScreenHeight()); return true
        case "g":
            if shift {
                // Shift+g → bottom. (caps-locked g also lands here
                // because keyboardGetUnicodeString lowercases via
                // our caller; but the shift FLAG is what we look at,
                // so caps-lock without shift correctly stays on `gg`.)
                jump(toTop: false); return true
            }
            // Lowercase g: if pressed twice within the chord
            // window → top. First g just primes.
            let now = CACurrentMediaTime()
            if let prev = lastG, now - prev < Self.chordWindow {
                lastG = nil
                jump(toTop: true)
            } else {
                lastG = now
            }
            return true
        default:
            stop()
            onExit()
            return false
        }
    }

    // MARK: - Dispatch

    /// Synthesise a wheel scroll event in pixel units. `delta > 0`
    /// scrolls visually upward (page content moves down) — same
    /// convention as `CGEventCreateScrollWheelEvent`. Sent at the
    /// session tap so the focused window receives it without perch
    /// needing focus.
    private func scroll(by delta: Int32) {
        guard let evt = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: delta, wheel2: 0, wheel3: 0)
        else {
            Log.line("scroll: CGEvent create failed")
            return
        }
        evt.post(tap: .cgSessionEventTap)
    }

    /// `gg` / `G` — fire several large notches to walk all the way
    /// to the edge. macOS scroll views clamp at the bounds, so
    /// over-shooting is safe and avoids needing per-app AX glue.
    private func jump(toTop: Bool) {
        let dir: Int32 = toTop ? 1 : -1
        for _ in 0..<20 {
            scroll(by: dir * 4000)
        }
    }

    private static func halfScreenHeight() -> Int32 {
        let h = NSScreen.main?.frame.height ?? 800
        return Int32(h / 2)
    }

    private static func resolveCancelKeyCode(_ name: String) -> CGKeyCode {
        if let kc = HotkeyMonitor.keyCode(for: name) {
            return CGKeyCode(kc)
        }
        return 53
    }
}

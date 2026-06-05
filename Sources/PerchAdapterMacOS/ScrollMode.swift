// Keyboard-driven scrolling. Once entered (via `perch --scroll`),
// perch installs a KeyTap that intercepts a small set of vim-style
// keys and synthesises the corresponding `CGEvent` scroll-wheel
// events against the frontmost window — same way every browser
// keyboard-nav extension wires up scroll. macOS dispatches the
// synthesised event to whichever window has focus, so perch can
// stay headless / non-active throughout.
//
// Bindings:
//   j        scroll DOWN  by one notch (≈ 50 px)
//   k        scroll UP    by one notch
//   d / Ctrl+d   scroll DOWN  by half a screen
//   u / Ctrl+u   scroll UP    by half a screen
//   Ctrl+f   scroll DOWN  by a full screen
//   Ctrl+b   scroll UP    by a full screen
//   gg       scroll to top (g pressed twice in succession)
//   G        scroll to bottom (Shift+g)
//   <digits> prefix-multiplier for the next motion ("5j" → 5 notches)
//   esc      exit scroll mode
//   any other key → exit scroll mode and let the key through
//
// Count buffer (issue #56):
//   Digits before a motion key buffer up and multiply the motion.
//   `12j` scrolls 12 notches; the count is consumed on motion fire
//   and cleared on Esc / unrecognised key. A bare leading `0` is
//   NOT a count (vim convention) — `0` with an empty buffer exits
//   the mode like any other unmapped key. The count is capped at
//   200 so a typo (`999999j`) can't pin the daemon spinning.
//
// `gg` / `G` go top / bottom by sending many large scroll deltas
// because there's no AX "scroll to extreme" verb that works
// reliably across native apps; the wheel event is the lowest
// common denominator. Counts ARE consumed on `gg` / `G` (so a
// stray prefix doesn't carry over) but don't multiply — there's
// no useful "go to top 5 times".
//
// Ctrl+d / Ctrl+u / Ctrl+f / Ctrl+b are the vim canonical
// bindings; the plain-letter `d` / `u` are kept as aliases
// (no breaking change for muscle-memory users). Other
// `Ctrl+<letter>` combos exit the mode and pass through, so
// system shortcuts (Ctrl+C, Ctrl+A, Ctrl+T in the terminal)
// keep working.

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
    private var countBuf: String = ""                // <digit>* prefix
    private let onExit: () -> Void

    private static let notch: Int32 = 50
    private static let chordWindow: TimeInterval = 0.5
    /// Hard cap on the count multiplier so a typo (`999999j`)
    /// can't pin perch in a long synthetic scroll. macOS
    /// scroll views clamp at the bounds anyway, so 200 large
    /// deltas reach any document end.
    private static let maxCount: Int = 200

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
        countBuf = ""
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
        // Esc — exit silently, clearing any pending count.
        if keyCode == cancelKeyCode {
            stop()
            onExit()
            return true
        }

        let ctrl = flags.contains(.maskControl)
        let shift = flags.contains(.maskShift)
        let ch = char.first

        // Digit buffering — only when no modifiers are held. A bare
        // leading `0` is unmapped (matches vim's "0 = start of line"
        // semantics, which doesn't translate to scrolling); the
        // unmapped path drops out of scroll mode like any other
        // unknown key. Once the buffer is non-empty, `0` is a
        // legitimate digit (`10`, `20`, …).
        if !ctrl, !shift, let c = ch, c.isASCII, c.isNumber,
           !(c == "0" && countBuf.isEmpty) {
            countBuf.append(c)
            Log.debug("scroll: count buffer=\"\(countBuf)\"")
            return true
        }

        switch (ctrl, shift, ch) {
        case (false, false, "j"):
            return fireNotch(direction: -1, label: "j")
        case (false, false, "k"):
            return fireNotch(direction: +1, label: "k")
        case (false, false, "d"), (true, false, "d"):
            return fireHalf(direction: -1, label: ctrl ? "ctrl-d" : "d")
        case (false, false, "u"), (true, false, "u"):
            return fireHalf(direction: +1, label: ctrl ? "ctrl-u" : "u")
        case (true, false, "f"):
            return fireFull(direction: -1, label: "ctrl-f")
        case (true, false, "b"):
            return fireFull(direction: +1, label: "ctrl-b")
        case (false, true, "g"):
            // Shift+g → bottom. Consume any pending count so a stray
            // prefix doesn't leak forward; counts don't multiply
            // "go to bottom".
            consumeCount(for: "G")
            jump(toTop: false)
            return true
        case (false, false, "g"):
            // Lowercase g: if pressed twice within the chord window
            // → top. The first g primes WITHOUT consuming countBuf
            // — `5gg` keeps the `5` alive across the chord even
            // though we'll ignore it on the dispatch.
            let now = CACurrentMediaTime()
            if let prev = lastG, now - prev < Self.chordWindow {
                lastG = nil
                consumeCount(for: "gg")
                jump(toTop: true)
            } else {
                lastG = now
            }
            return true
        case (true, _, _):
            // Ctrl + unrecognised letter → exit + pass through, so
            // the user's system shortcuts (Ctrl+C, Ctrl+A, …) keep
            // working. Don't carry the count out of the mode.
            countBuf = ""
            stop()
            onExit()
            return false
        default:
            countBuf = ""
            stop()
            onExit()
            return false
        }
    }

    /// Resolve the pending count, log the motion, and clear the
    /// buffer. Returns the value to multiply the motion by.
    /// Always >= 1 (a parsed `0` shouldn't ever land here because
    /// the bare-zero guard in `handle` rejects it).
    private func consumeCount(for label: String) -> Int {
        let parsed = Int(countBuf) ?? 1
        let n = max(1, min(parsed, Self.maxCount))
        Log.line("scroll: count=\(n) \(label)")
        countBuf = ""
        return n
    }

    private func fireNotch(direction: Int32, label: String) -> Bool {
        let n = consumeCount(for: label)
        scroll(by: direction * Self.notch * Int32(n))
        return true
    }

    private func fireHalf(direction: Int32, label: String) -> Bool {
        let n = consumeCount(for: label)
        scroll(by: direction * Self.halfScreenHeight() * Int32(n))
        return true
    }

    private func fireFull(direction: Int32, label: String) -> Bool {
        let n = consumeCount(for: label)
        scroll(by: direction * Self.fullScreenHeight() * Int32(n))
        return true
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

    /// Full-screen height for `Ctrl+f` / `Ctrl+b` (issue #56). Falls
    /// back to 800 when no main screen is reachable (headless test
    /// runners, deferred display detach) — same defensive default
    /// as the half-screen helper.
    private static func fullScreenHeight() -> Int32 {
        let h = NSScreen.main?.frame.height ?? 800
        return Int32(h)
    }

    private static func resolveCancelKeyCode(_ name: String) -> CGKeyCode {
        if let kc = HotkeyMonitor.keyCode(for: name) {
            return CGKeyCode(kc)
        }
        return 53
    }
}

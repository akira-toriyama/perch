// Keyboard-driven drag-and-drop (issue #69 / M4-δ). Vimac /
// Homerow / Shortcat don't handle drag well because there's no
// single AX target representing the operation. Drag mode fills
// the gap with a 2-phase state machine on top of nudge-style
// cursor movement.
//
// State machine:
//
//   .positioning ── arrows → cursor move (nudge-style)
//                 \
//                  d → mouseDown at current cursor
//                       │
//                       ▼
//                    .dragging ── arrows → cursor move + mouseDragged
//                              \
//                               d / space / Enter → mouseUp + exit
//                               Esc → mouseUp (safety) + exit
//
// Step sizes during cursor movement mirror `overlay --nudge`: bare 1 px,
// Shift 10 px, Alt 100 px, Cmd screen-edge. The arrow / modifier
// vocabulary is identical to nudge mode by design — once you
// know nudge, you know drag positioning.
//
// **Esc is a safety release, NOT a cancel.** If the user is in
// `.dragging` state and presses Esc, perch fires `leftMouseUp`
// at the current cursor BEFORE tearing down — leaving an
// unmatched `mouseDown` in the system input queue is dangerous
// (the next click would behave as if "shift held" against an
// already-selected range, etc.). The drop happens wherever the
// cursor was; the user can undo if that wasn't what they wanted.
//
// Visual feedback: none for v1. The cursor's mouse-down state
// IS the feedback — apps highlight drag-over targets, the
// cursor often changes shape (closed hand, no-entry sign, etc.).
// Future follow-up: a small panel banner ("DRAG IN PROGRESS")
// once usage signals that the cursor change alone isn't enough.

import AppKit
import CoreGraphics
import Foundation
import PerchCore

@MainActor
public final class DragMode {

    private enum Phase {
        case positioning   // cursor free, no button held
        case dragging      // mouseDown fired, button held
    }

    private var phase: Phase = .positioning
    private var keyTap: KeyTap?
    private var cancelKeyCode: CGKeyCode = 53
    private let onExit: () -> Void

    // Step sizes match `NudgeMode`. Duplicated rather than shared
    // because the two modes are independent — if one grows
    // configurability later (e.g. user-tuned step sizes), the
    // other shouldn't follow blindly.
    private static let stepSmall: CGFloat = 1
    private static let stepMedium: CGFloat = 10
    private static let stepLarge: CGFloat = 100
    private static let stepEdge: CGFloat = 10_000

    public init(cancelKey: String, onExit: @escaping () -> Void) {
        self.cancelKeyCode = Self.resolveCancelKeyCode(cancelKey)
        self.onExit = onExit
    }

    @discardableResult
    public func start() -> Bool {
        guard keyTap == nil else { return true }
        let tap = KeyTap { [weak self] kc, flags, char in
            guard let self else { return false }
            return MainActor.assumeIsolated {
                self.handle(kc: kc, flags: flags, char: char)
            }
        }
        guard tap.install() else {
            Log.line("drag: keytap install failed — bailing")
            onExit()
            return false
        }
        keyTap = tap
        phase = .positioning
        Log.line("drag: mode entered (.positioning — `d` to grab)")
        return true
    }

    public func stop() {
        // Safety: if we're in .dragging when stop() runs (e.g.
        // user pressed the global hotkey to cancel everything),
        // release the mouse before tearing down so we don't strand
        // a mouseDown in the system input queue.
        if phase == .dragging {
            releaseDrag(at: currentCursor())
        }
        keyTap?.uninstall()
        keyTap = nil
        phase = .positioning
        Log.line("drag: mode exited")
    }

    // MARK: - Key handling

    private func handle(
        kc: CGKeyCode, flags: CGEventFlags, char: String
    ) -> Bool {
        // Esc / cancel-key: safety release THEN exit. Don't strand
        // the mouseDown.
        if kc == cancelKeyCode {
            if phase == .dragging {
                releaseDrag(at: currentCursor())
            }
            stop()
            onExit()
            return true
        }
        // Ctrl reserved for user shortcuts (Ctrl+C etc.). If
        // we're dragging, release first so the system stays sane,
        // then exit + let the Ctrl combo through.
        if flags.contains(.maskControl) {
            if phase == .dragging {
                releaseDrag(at: currentCursor())
            }
            stop()
            onExit()
            return false
        }
        // Arrow → cursor movement. In .dragging, post mouseDragged
        // so the receiving app updates its drag-over visualization.
        if let dir = Self.arrowDirection(kc) {
            let step = Self.stepFor(flags: flags)
            move(dx: dir.x * step, dy: dir.y * step)
            return true
        }
        // `d` / space / Enter — phase transition. In .positioning
        // it's "grab" (mouseDown); in .dragging it's "release"
        // (mouseUp + exit).
        if Self.isActionKey(kc, char: char) {
            switch phase {
            case .positioning:
                grabDrag(at: currentCursor())
                return true
            case .dragging:
                releaseDrag(at: currentCursor())
                stop()
                onExit()
                return true
            }
        }
        // Anything else: in .positioning just exit. In .dragging
        // release first (safety) — then exit.
        if phase == .dragging {
            releaseDrag(at: currentCursor())
        }
        stop()
        onExit()
        return false
    }

    // MARK: - Drag verbs

    /// Phase transition: `.positioning` → `.dragging`. Posts a
    /// `leftMouseDown` at the current cursor. The receiving app
    /// sees this as the start of a drag (or a click that hasn't
    /// completed); subsequent `mouseDragged` events will track
    /// the cursor.
    private func grabDrag(at point: CGPoint) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                mouseEventSource: src,
                mouseType: .leftMouseDown,
                mouseCursorPosition: point,
                mouseButton: .left)
        else {
            Log.line("drag: mouseDown CGEvent create failed")
            return
        }
        down.post(tap: .cghidEventTap)
        phase = .dragging
        Log.line("drag: grabbed at "
                 + "(\(Int(point.x)),\(Int(point.y))) — "
                 + "`d` / space / Enter to release")
    }

    /// Phase transition: `.dragging` → `.positioning`. Posts a
    /// `leftMouseUp` at the current cursor — completes the drop.
    /// Idempotent guard: if `phase` is already `.positioning`
    /// (e.g. caller invoked us defensively), no-op.
    private func releaseDrag(at point: CGPoint) {
        guard phase == .dragging else { return }
        guard let src = CGEventSource(stateID: .hidSystemState),
              let up = CGEvent(
                mouseEventSource: src,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left)
        else {
            Log.line("drag: mouseUp CGEvent create failed — "
                     + "system may be left in held state")
            phase = .positioning
            return
        }
        up.post(tap: .cghidEventTap)
        phase = .positioning
        Log.line("drag: released at "
                 + "(\(Int(point.x)),\(Int(point.y)))")
    }

    /// Move the cursor. In `.positioning` it's a plain warp +
    /// hover (same as `NudgeMode`); in `.dragging` we ALSO post
    /// a `mouseDragged` event so the receiving app sees the
    /// drag-over update (highlights drop targets, etc.).
    private func move(dx: CGFloat, dy: CGFloat) {
        let from = currentCursor()
        let target = CGPoint(x: from.x + dx, y: from.y + dy)
        _ = CGWarpMouseCursorPosition(target)

        let evtType: CGEventType =
            (phase == .dragging) ? .leftMouseDragged : .mouseMoved
        if let src = CGEventSource(stateID: .hidSystemState),
           let evt = CGEvent(
            mouseEventSource: src,
            mouseType: evtType,
            mouseCursorPosition: target,
            mouseButton: .left) {
            evt.post(tap: .cghidEventTap)
        }
        Log.debug("drag: \(phase) "
                  + "(\(Int(from.x)),\(Int(from.y))) → "
                  + "(\(Int(target.x)),\(Int(target.y)))")
    }

    // MARK: - Helpers (parallel to NudgeMode)

    private func currentCursor() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private static func arrowDirection(_ kc: CGKeyCode) -> (x: CGFloat, y: CGFloat)? {
        switch kc {
        case 123: return (-1, 0)        // Left
        case 124: return (+1, 0)        // Right
        case 125: return (0, +1)        // Down
        case 126: return (0, -1)        // Up
        default: return nil
        }
    }

    /// `d` (keycode 2) is the canonical "grab / release" verb
    /// (scoot uses `=`, Mouseless uses "hold for drag" — `d`
    /// reads as "drag" and is free in this mode's vocabulary).
    /// `space` / `Enter` / `KeypadEnter` are aliases for users
    /// who already think of space-as-confirm from other modes.
    private static func isActionKey(_ kc: CGKeyCode, char: String) -> Bool {
        if kc == 49 || kc == 36 || kc == 76 { return true } // space, Return, Keypad
        if let ch = char.first, ch.lowercased() == "d" { return true }
        return false
    }

    private static func stepFor(flags: CGEventFlags) -> CGFloat {
        if flags.contains(.maskCommand)   { return stepEdge }
        if flags.contains(.maskAlternate) { return stepLarge }
        if flags.contains(.maskShift)     { return stepMedium }
        return stepSmall
    }

    private static func resolveCancelKeyCode(_ name: String) -> CGKeyCode {
        if let kc = HotkeyMonitor.keyCode(for: name) {
            return CGKeyCode(kc)
        }
        return 53
    }
}

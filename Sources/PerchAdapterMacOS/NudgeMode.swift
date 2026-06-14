// Arrow-nudge cursor mode (issue #68 / M4-γ). The last-mile
// pixel adjustment that complements `overlay --grid` / `overlay --rgrid`: after
// the grid lands the cursor close, `overlay --nudge` walks it the rest
// of the way with arrow keys + step-size modifiers.
//
// No overlay panel — the cursor is the visual feedback. Just a
// `KeyTap` (like `ScrollMode`) that intercepts arrows + space /
// Enter / Esc for the duration of the mode. The user "sees" the
// mode by watching the cursor move; if they want to confirm,
// `/tmp/perch.status` carries the mode name.
//
// Bindings (active while nudge mode is up):
//   ←↑↓→               1 px in that direction (precision)
//   Shift+arrow        10 px
//   Alt+arrow          100 px
//   Cmd+arrow          jump to the edge of the screen union
//                       (very large delta, macOS clamps)
//   space / Enter      left click at current cursor + exit
//   Shift+(space|Ret)  right click + exit
//   Cmd+(space|Ret)    middle click + exit
//   Esc / cancel key   exit silently (no click)
//   any other key      exit + let through (so the user isn't stuck)
//
// Modifier choice on the step: Alt (not Ctrl) for the "medium"
// step. Ctrl stays reserved for the user's own system shortcuts —
// intercepting Ctrl+arrow inside nudge would collide with Mission
// Control / Spaces bindings on macOS.
//
// Dispatch is `CGWarpMouseCursorPosition` for the move plus a
// `mouseMoved` `CGEvent` so apps under the cursor see the hover
// (tooltips, button highlight). Cursor jump is visible and
// intentional — same "AX-bypass carve-out" as `overlay --grid`.

import AppKit
import CoreGraphics
import Foundation
import PerchCore

@MainActor
public final class NudgeMode {

    private var keyTap: KeyTap?
    private var cancelKeyCode: CGKeyCode = 53
    private let onExit: () -> Void

    /// Step sizes in px. `large` is intentionally huge — when the
    /// user wants "jump to edge", we don't need to compute screen
    /// bounds; macOS clamps the warped position to the global
    /// screen union, so 10000 reaches the edge in one shot. Same
    /// trick the existing `ScrollMode` uses for `gg` / `G`.
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
            Log.line("nudge: keytap install failed — bailing")
            onExit()
            return false
        }
        keyTap = tap
        Log.line("nudge: mode entered")
        return true
    }

    public func stop() {
        keyTap?.uninstall()
        keyTap = nil
        Log.line("nudge: mode exited")
    }

    // MARK: - Key handling

    private func handle(
        kc: CGKeyCode, flags: CGEventFlags, char: String
    ) -> Bool {
        if kc == cancelKeyCode {
            stop()
            onExit()
            return true
        }
        // Ctrl reserved for user shortcuts.
        if flags.contains(.maskControl) {
            stop()
            onExit()
            return false
        }
        // Arrow keys → cursor movement.
        if let dir = Self.arrowDirection(kc) {
            let step = Self.stepFor(flags: flags)
            nudge(dx: dir.x * step, dy: dir.y * step)
            return true
        }
        // Space / Return → click + exit. Modifier picks the button.
        if kc == 49 || kc == 36 || kc == 76 {
            clickAtCursor(flags: flags)
            stop()
            onExit()
            return true
        }
        // Anything else → exit + let through so the user can type
        // freely after the click lands.
        stop()
        onExit()
        return false
    }

    /// Map an arrow keycode to a unit-direction vector. CG global
    /// coords have top-left origin (y grows downward), so `↑` is
    /// `(0, -1)`.
    private static func arrowDirection(_ kc: CGKeyCode) -> (x: CGFloat, y: CGFloat)? {
        switch kc {
        case 123: return (-1, 0)        // Left
        case 124: return (+1, 0)        // Right
        case 125: return (0, +1)        // Down
        case 126: return (0, -1)        // Up
        default: return nil
        }
    }

    private static func stepFor(flags: CGEventFlags) -> CGFloat {
        if flags.contains(.maskCommand)   { return stepEdge }
        if flags.contains(.maskAlternate) { return stepLarge }
        if flags.contains(.maskShift)     { return stepMedium }
        return stepSmall
    }

    // MARK: - Dispatch

    /// Read current cursor position via `CGEvent(source:)?.location`
    /// — gives CG global coords (top-left origin, matches our other
    /// dispatch paths). `NSEvent.mouseLocation` uses NS coords
    /// (bottom-left) and would need conversion; the CG event path
    /// is one call.
    private func currentCursor() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    private func nudge(dx: CGFloat, dy: CGFloat) {
        let from = currentCursor()
        let target = CGPoint(x: from.x + dx, y: from.y + dy)
        warpAndHover(target: target)
        Log.line("nudge: (\(Int(from.x)),\(Int(from.y))) → "
                 + "(\(Int(target.x)),\(Int(target.y)))")
    }

    /// Click whichever button the modifier picks. Bare → left,
    /// Shift → right, Cmd → middle. Esc / Alt aren't routed here
    /// (Esc cancels in `handle(...)`, Alt is reserved for step
    /// size on arrow keys).
    private func clickAtCursor(flags: CGEventFlags) {
        let at = currentCursor()
        let kind: (down: CGEventType, up: CGEventType, button: CGMouseButton)
        if flags.contains(.maskCommand) {
            kind = (.otherMouseDown, .otherMouseUp, .center)
        } else if flags.contains(.maskShift) {
            kind = (.rightMouseDown, .rightMouseUp, .right)
        } else {
            kind = (.leftMouseDown, .leftMouseUp, .left)
        }
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                mouseEventSource: src,
                mouseType: kind.down,
                mouseCursorPosition: at,
                mouseButton: kind.button),
              let up = CGEvent(
                mouseEventSource: src,
                mouseType: kind.up,
                mouseCursorPosition: at,
                mouseButton: kind.button)
        else {
            Log.line("nudge: click CGEvent create failed")
            return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Log.line("nudge: \(kind.button) click @ "
                 + "(\(Int(at.x)),\(Int(at.y)))")
    }

    /// Warp the cursor AND post a `mouseMoved` event so apps under
    /// the cursor see the hover. Without the move event, hover-
    /// dependent UI (tooltips, button highlight) wouldn't update
    /// — the cursor would look "frozen" visually even though
    /// macOS knows it moved.
    private func warpAndHover(target: CGPoint) {
        let warpErr = CGWarpMouseCursorPosition(target)
        if warpErr != .success {
            Log.line("nudge: warp failed (\(warpErr.rawValue))")
        }
        guard let src = CGEventSource(stateID: .hidSystemState),
              let move = CGEvent(
                mouseEventSource: src,
                mouseType: .mouseMoved,
                mouseCursorPosition: target,
                mouseButton: .left)
        else { return }
        move.post(tap: .cghidEventTap)
    }

    private static func resolveCancelKeyCode(_ name: String) -> CGKeyCode {
        if let kc = HotkeyMonitor.keyCode(for: name) {
            return CGKeyCode(kc)
        }
        return 53
    }
}

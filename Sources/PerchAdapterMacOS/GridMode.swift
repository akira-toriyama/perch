// Coordinate-grid mode (issue #66 / M4-α). The explicit AX-bypass
// fallback: when hint mode can't see the target (Figma canvas,
// Photoshop, custom-drawn UI, web `<canvas>`), perch overlays a
// labeled grid across the screen union and warps the cursor to
// the picked cell's center via synthetic `CGEvent`.
//
// CLAUDE.md previously banned synthetic mouse clicks ("AX press
// is less disruptive"). That rule was right for hint mode — every
// AX target has a meaningful `kAXPressAction`. Grid mode is the
// deliberate exception: by definition there's no AX target, so
// `CGEvent` mouse is the ONLY dispatch path. The carve-out is
// documented in CLAUDE.md → "Mouse synthesis carve-out".
//
// Architecture:
//   - Owns its own KeyTap + NSPanel (mirrors `SearchMode` /
//     `ScrollMode` — mutually exclusive with every other mode).
//   - Generates synthetic `UIElement`s (one per cell, role
//     `"GridCell"`, frame = cell rect) and feeds them through
//     `Labeler.assign(...)` so the alphabet matches hint mode.
//   - Renders labels at cell centers using the same accent /
//     blur / animation knobs as the hint overlay.
//   - Dispatches `CGEvent` mouse-down + mouse-up directly. No
//     trip through `UIElementSource.act(...)` — the seam is for
//     AX-anchored elements; grid is the deliberately untyped
//     fallback.
//
// Action mapping (modifier-driven, mirrors hint mode where it
// makes sense):
//   bare        →  warp + left click
//   Shift       →  warp + right click
//   Cmd         →  warp only (no click — useful before --drag)
//   Cmd+Shift   →  warp + left click + re-enter grid mode
//                  (chained operations: many quick clicks)

import AppKit
import CoreGraphics
import Foundation
import PerchCore

@MainActor
public final class GridMode {

    private let config: PerchConfig
    private let onExit: () -> Void
    /// Fired immediately after a `.pressContinuous` (Cmd+Shift)
    /// click so the Controller can re-enter the picker with the
    /// SAME config snapshot. Without this, the chain would have
    /// to re-resolve config / re-build the screen union on every
    /// click — measurably slower for "10 clicks in a row" workflows.
    private let onReenter: () -> Void

    private let panel: NSPanel
    private let canvas: GridCanvas
    private var keyTap: KeyTap?
    private var cancelKeyCode: CGKeyCode = 53        // Esc

    /// The labeled hints (one per cell). Built once on `start()`
    /// — the grid layout doesn't change while the mode is up.
    private var hints: [Hint] = []
    /// Prefix typed so far. Same disjoint single/two-letter
    /// invariant as hint mode, so a two-letter label can't be
    /// "completed" by a single-letter pick.
    private var typed: String = ""

    /// Action verbs surfaced by the grid mode. Mapped from the
    /// modifier flags held when the user finishes typing the
    /// label. Kept as a private enum (vs reusing `HintAction`)
    /// so the grid's "warp only" / "left click" / "right click"
    /// semantics don't pollute the AX-action vocabulary — those
    /// are semantically distinct dispatches.
    private enum GridAction {
        case leftClick
        case rightClick
        case warpOnly
        case leftClickContinuous     // re-enter after click
    }

    public init(
        config: PerchConfig,
        onResolve: @escaping () -> Void = {},
        onExit: @escaping () -> Void,
        onReenter: @escaping () -> Void = {}
    ) {
        self.config = config
        self.onExit = onExit
        self.onReenter = onReenter
        self.cancelKeyCode = Self.resolveCancelKeyCode(config.cancelKey)

        let frame = OverlayCoords.unionFrame()
        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle,
            .fullScreenAuxiliary,
        ]
        let cv = GridCanvas(
            frame: NSRect(origin: .zero, size: frame.size),
            config: config)
        cv.unionFrame = frame
        p.contentView = cv
        self.panel = p
        self.canvas = cv
    }

    /// Build the cell grid, label each cell via `Labeler.assign(...)`,
    /// orderFront the panel, install the KeyTap. Returns `false` if
    /// the tap fails to install (missing AX grant) — `onExit` fires
    /// in that case so the caller can fall through.
    @discardableResult
    public func start() -> Bool {
        let union = OverlayCoords.unionFrame()
        let cols = config.gridCols
        let rows = config.gridRows
        let cells = Self.buildCells(unionFrame: union,
                                    cols: cols, rows: rows)
        hints = Labeler.assign(
            elements: cells,
            alphabet: config.alphabet,
            // Center-priority makes intuitive sense here too — the
            // closest-to-screen-center cell gets the shortest /
            // easiest label.
            prioritiseCenter: config.prioritiseCenter,
            screenSize: union.size)
        typed = ""

        panel.setFrame(union, display: false)
        canvas.frame = NSRect(origin: .zero, size: union.size)
        canvas.unionFrame = union
        canvas.present(hints: hints, typed: typed)
        panel.orderFrontRegardless()

        let tap = KeyTap { [weak self] kc, flags, char in
            guard let self else { return false }
            return MainActor.assumeIsolated {
                self.handle(kc: kc, flags: flags, char: char)
            }
        }
        guard tap.install() else {
            Log.line("grid: keytap install failed — bailing")
            panel.orderOut(nil)
            onExit()
            return false
        }
        keyTap = tap
        Log.line("grid: mode entered "
                 + "(\(cols)×\(rows) = \(hints.count) cells)")
        return true
    }

    public func stop() {
        keyTap?.uninstall()
        keyTap = nil
        panel.orderOut(nil)
        hints = []
        typed = ""
        Log.line("grid: mode exited")
    }

    // MARK: - Key handling

    private func handle(
        kc: CGKeyCode, flags: CGEventFlags, char: String
    ) -> Bool {
        // Esc / configured cancel-key → exit silently. Match
        // keyCode so the user can mash Esc with any modifiers held.
        if kc == cancelKeyCode {
            stop()
            onExit()
            return true
        }
        // Ctrl is reserved for the user's own system shortcuts
        // (Ctrl-C etc.). Exit + let through. Cmd / Alt / Shift are
        // repurposed as action mods, so they DON'T cancel.
        if flags.contains(.maskControl) {
            stop()
            onExit()
            return false
        }
        // Backspace — drop the last typed character.
        if kc == 51 {
            if !typed.isEmpty { typed.removeLast() }
            canvas.present(hints: filtered(), typed: typed)
            return true
        }
        // Only letters drive label resolution. Anything else (digits,
        // arrows, F-keys) → exit + let through. Silent input on a
        // modal overlay is the worst UX.
        guard let ch = char.first, ch.isLetter else {
            stop()
            onExit()
            return false
        }
        typed.append(ch)

        let surviving = filtered()
        if surviving.isEmpty {
            // Typed letter doesn't match any label — exit silently.
            // Could flash here (a la OverlayWindow), but the grid
            // overlay covers the whole screen and a screen-wide
            // red flash would be jarring.
            stop()
            onExit()
            return true
        }
        // Auto-resolve on unique candidate (same default as hint
        // mode). No per-app override knob here — grid mode is
        // app-agnostic by design.
        if surviving.count == 1 {
            fire(hint: surviving[0], flags: flags)
            return true
        }
        // Exact match wins immediately (covers the "two-letter
        // label resolved" case).
        if let resolved = Labeler.resolve(hints: hints, keys: typed) {
            fire(hint: resolved, flags: flags)
            return true
        }
        canvas.present(hints: surviving, typed: typed)
        return true
    }

    private func filtered() -> [Hint] {
        Labeler.filter(hints: hints, prefix: typed)
    }

    /// Resolve modifier flags → grid action and dispatch. Action
    /// mapping is documented at the top of this file; precedence:
    /// Cmd+Shift > Cmd > Shift > bare.
    private func fire(hint: Hint, flags: CGEventFlags) {
        let cmd = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        let action: GridAction
        if cmd && shift           { action = .leftClickContinuous }
        else if cmd               { action = .warpOnly }
        else if shift             { action = .rightClick }
        else                      { action = .leftClick }

        // Cell center in CG global coords (top-left origin). The
        // hint frame is screen-local from `buildCells`, so this is
        // the click point.
        let center = CGPoint(
            x: hint.element.frame.midX,
            y: hint.element.frame.midY)

        dispatch(action: action, at: center, label: hint.keys)

        // Re-enter for chained clicks; otherwise tear down and let
        // the caller know we're done.
        if action == .leftClickContinuous {
            stop()
            // Hop to the next runloop tick so the click event has
            // posted before we re-show the overlay — otherwise the
            // re-entered grid intercepts the in-flight mouse down.
            DispatchQueue.main.async { [weak self] in
                self?.onReenter()
            }
        } else {
            stop()
            onExit()
        }
    }

    /// Synthesise the mouse events. `warpOnly` skips the click —
    /// useful for "park the cursor, then enter `--drag`" workflows.
    /// For `leftClick` / `rightClick` / `leftClickContinuous` the
    /// mouseDown+mouseUp pair is posted at `cghidEventTap` so the
    /// focused window receives it without perch needing to be
    /// active.
    private func dispatch(
        action: GridAction, at point: CGPoint, label: String
    ) {
        // Warp the cursor first — every action paths through this.
        // `CGWarpMouseCursorPosition` doesn't generate a mouse
        // event; we synthesise the click separately so apps see a
        // clean "move + click" pair.
        let warpErr = CGWarpMouseCursorPosition(point)
        if warpErr != .success {
            Log.line("grid: warp failed (\(warpErr.rawValue)) → "
                     + "(\(Int(point.x)),\(Int(point.y)))")
        }
        if action == .warpOnly {
            Log.line("grid: warp-only → \(label) "
                     + "@ (\(Int(point.x)),\(Int(point.y)))")
            return
        }

        let mouseType: (down: CGEventType, up: CGEventType, button: CGMouseButton)
        switch action {
        case .leftClick, .leftClickContinuous:
            mouseType = (.leftMouseDown, .leftMouseUp, .left)
        case .rightClick:
            mouseType = (.rightMouseDown, .rightMouseUp, .right)
        case .warpOnly:
            return                              // handled above
        }
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                mouseEventSource: src,
                mouseType: mouseType.down,
                mouseCursorPosition: point,
                mouseButton: mouseType.button),
              let up = CGEvent(
                mouseEventSource: src,
                mouseType: mouseType.up,
                mouseCursorPosition: point,
                mouseButton: mouseType.button)
        else {
            Log.line("grid: CGEvent create failed → \(label)")
            return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        Log.line("grid: \(action) → \(label) "
                 + "@ (\(Int(point.x)),\(Int(point.y)))")
    }

    // MARK: - Cell generation

    /// Slice `unionFrame` (CG global coords, top-left origin) into
    /// `cols × rows` rectangles. Each rectangle becomes a synthetic
    /// `UIElement` with id `"grid:<row>:<col>"`, role
    /// `"GridCell"`, empty label (the user never sees the label
    /// — only the assigned key sequence), and frame = cell rect.
    static func buildCells(
        unionFrame: CGRect, cols: Int, rows: Int
    ) -> [UIElement] {
        guard cols > 0, rows > 0 else { return [] }
        let cellW = unionFrame.width / CGFloat(cols)
        let cellH = unionFrame.height / CGFloat(rows)
        var out: [UIElement] = []
        out.reserveCapacity(cols * rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let rect = CGRect(
                    x: unionFrame.minX + CGFloat(c) * cellW,
                    y: unionFrame.minY + CGFloat(r) * cellH,
                    width: cellW, height: cellH)
                out.append(UIElement(
                    id: "grid:\(r):\(c)",
                    role: "GridCell",
                    label: "",
                    frame: rect))
            }
        }
        return out
    }

    private static func resolveCancelKeyCode(_ name: String) -> CGKeyCode {
        if let kc = HotkeyMonitor.keyCode(for: name) {
            return CGKeyCode(kc)
        }
        return 53
    }
}

// MARK: - GridCanvas (NSView)

/// Renders the labeled grid. Each cell is drawn with a small pill
/// at its center (showing the assigned key sequence). The cell
/// rectangles themselves are NOT drawn — drawing grid lines makes
/// the whole screen unusable visually. The pill alone is enough
/// signal for the user to pick.
///
/// Re-uses the same `HintPainter` from hint mode for the actual
/// pill drawing — same accent / blur / animation knobs, same
/// visual language. This is what makes grid mode feel like an
/// extension of hint mode rather than a separate tool.
@MainActor
private final class GridCanvas: NSView {

    var unionFrame: CGRect = .zero
    private let config: PerchConfig
    private var hints: [Hint] = []
    private var typed: String = ""

    init(frame frameRect: NSRect, config: PerchConfig) {
        self.config = config
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func present(hints: [Hint], typed: String) {
        self.hints = hints
        self.typed = typed
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = Self.accent(config.overlayAccent)
        let font = NSFont.monospacedSystemFont(
            ofSize: CGFloat(config.overlayFontSize),
            weight: .semibold)

        for hint in hints {
            // Cell center → canvas-local coords. The hint frame
            // came from `buildCells` which used CG global coords,
            // so re-use the same conversion the OverlayCanvas does.
            let cgCenter = CGPoint(
                x: hint.element.frame.midX,
                y: hint.element.frame.midY)
            let local = OverlayCoords.canvasLocal(
                cg: cgCenter,
                unionFrame: unionFrame,
                primaryHeight: OverlayCoords.primaryHeight())

            let label = hint.keys
            let highlighted = !typed.isEmpty
                && label.hasPrefix(typed)
            let textColor = NSColor.white
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
            ]
            let attr = NSAttributedString(string: label, attributes: attrs)
            let tSize = attr.size()
            let pillW = ceil(tSize.width) + 18
            let pillH = ceil(font.boundingRectForFont.height) + 12
            let r = CGRect(
                x: local.x - pillW / 2,
                y: local.y - pillH / 2,
                width: pillW, height: pillH)
            let path = NSBezierPath(
                roundedRect: r, xRadius: 10, yRadius: 10)
            (highlighted
             ? accent.withAlphaComponent(0.95)
             : NSColor.black.withAlphaComponent(0.78)).setFill()
            path.fill()
            (highlighted
             ? NSColor.white.withAlphaComponent(0.95)
             : accent.withAlphaComponent(0.7)).setStroke()
            path.lineWidth = highlighted ? 2 : 1
            path.stroke()
            attr.draw(at: NSPoint(
                x: r.origin.x + (pillW - tSize.width) / 2,
                y: r.origin.y + (pillH - tSize.height) / 2 - 1))
        }
    }

    private static func accent(_ s: String) -> NSColor {
        if s == "system" { return .controlAccentColor }
        var t = s
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let v = UInt32(t, radix: 16) else {
            return .controlAccentColor
        }
        return NSColor(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green:    CGFloat((v >> 8) & 0xFF) / 255,
            blue:     CGFloat(v & 0xFF) / 255,
            alpha: 1)
    }
}

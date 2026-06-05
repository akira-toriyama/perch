// Coordinate-grid mode (issue #66 / M4-α + issue #67 / M4-β).
// The explicit AX-bypass fallback: when hint mode can't see the
// target (Figma canvas, Photoshop, custom-drawn UI, web `<canvas>`),
// perch overlays a labeled grid across the screen union and warps
// the cursor to the picked cell's center via synthetic `CGEvent`.
//
// `--grid` enters with `maxDepth = 1` — a single grid pass, label
// pick → click. `--rgrid` (M4-β) enters with `maxDepth = config.
// gridMaxDepth` (default 3) — each label pick subdivides the
// chosen cell and re-renders a finer grid until the depth budget
// runs out. The terminal action (click) happens either at the
// final depth automatically OR earlier via `space` / `Enter` (the
// "good enough, click here" shortcut). `Backspace` pops one level
// (returns to the parent grid) so a misclick doesn't force a
// restart.
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
    /// Max subdivision depth. `1` (the `--grid` entry) means single
    /// pass: label pick fires the terminal action immediately.
    /// `>1` (the `--rgrid` entry, M4-β) means each label drills
    /// into the picked cell up to `maxDepth` times.
    private let maxDepth: Int
    private let onExit: () -> Void
    /// Fired immediately after a `.pressContinuous` (Cmd+Shift)
    /// click so the Controller can re-enter the picker with the
    /// SAME config snapshot. Without this, the chain would have
    /// to re-resolve config / re-build the screen union on every
    /// click — measurably slower for "10 clicks in a row" workflows.
    private let onReenter: () -> Void

    private let panel: NSPanel
    private let canvas: OverlayCanvas
    private let sound: SoundPlayer?
    private var keyTap: KeyTap?
    private var cancelKeyCode: CGKeyCode = 53        // Esc
    /// Hold-to-peek key code. While held, the panel orderOuts so the
    /// user can see the UI underneath the labeled grid; release
    /// restores. Same UX as hint mode's peek. nil → feature disabled.
    private var peekKeyCode: CGKeyCode?
    private var peeking = false

    /// The labeled hints (one per cell) for the **current** grid
    /// pass. Rebuilt on each drill so labels track the smaller
    /// rect.
    private var hints: [Hint] = []
    /// Prefix typed so far at the current depth. Cleared on drill
    /// + backspace so each level starts with an empty prefix.
    private var typed: String = ""
    /// 1-indexed depth of the currently-displayed grid. Starts at
    /// `1`; each drill increments. Reaching `maxDepth` makes the
    /// next label pick a terminal click instead of another drill.
    private var depth: Int = 1
    /// Rect currently being subdivided. Starts as the screen
    /// union; becomes the picked cell's rect on each drill.
    /// `space` / `Enter` clicks the center of this rect.
    private var currentFrame: CGRect = .zero
    /// Parent frames for `Backspace` pop. The top of the stack is
    /// the rect we were subdividing one level up. Empty stack at
    /// depth=1 means backspace is a no-op (don't pop past root).
    private var frameStack: [CGRect] = []

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

    /// Optional starting frame — when set, the grid subdivides
    /// this rect instead of the full screen union. Used by M5+
    /// nested grid (#74) so a `,g` chord on a hint can drill
    /// into the picked element's bounds. nil → screen-union as
    /// usual.
    private let initialFrame: CGRect?

    public init(
        config: PerchConfig,
        maxDepth: Int = 1,
        initialFrame: CGRect? = nil,
        sound: SoundPlayer? = nil,
        onResolve: @escaping () -> Void = {},
        onExit: @escaping () -> Void,
        onReenter: @escaping () -> Void = {}
    ) {
        self.config = config
        self.maxDepth = max(1, min(maxDepth, 5))
        self.initialFrame = initialFrame
        self.sound = sound
        self.onExit = onExit
        self.onReenter = onReenter
        self.cancelKeyCode = Self.resolveCancelKeyCode(config.cancelKey)
        self.peekKeyCode = Self.resolvePeekKeyCode(config.overlayPeekKey)

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
        // Use the shared OverlayCanvas — grid pills sit at cell
        // centers (`.elementCenter`) and pick up every visual
        // effect (theme / appear / match / unmatch / narrow /
        // border / pill-shape / modifier-badge) that hint mode
        // uses. The only behaviour split is the dispatch path
        // (synthetic CGEvent click vs AXPress) which lives in
        // GridMode, not the canvas.
        let cv = OverlayCanvas(
            frame: NSRect(origin: .zero, size: frame.size),
            config: config,
            placement: .elementCenter)
        cv.unionFrame = frame
        cv.primaryHeight = OverlayCoords.primaryHeight()
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
        depth = 1
        frameStack = []
        // Nested-grid (#74): start subdividing the picked
        // element's frame rather than the full screen. The panel
        // still covers the union (so labels render correctly
        // relative to global screen coords); only the
        // cell-generation rect differs.
        currentFrame = initialFrame ?? union
        rebuildHints()

        panel.setFrame(union, display: false)
        canvas.frame = NSRect(origin: .zero, size: union.size)
        canvas.unionFrame = union
        canvas.primaryHeight = OverlayCoords.primaryHeight()
        // Force fresh appear-effect on entry — `present()` checks
        // `pills.isEmpty` for the entrance trigger.
        canvas.clear()
        canvas.present(hints: hints, typed: typed)
        canvas.startBorderCycle()
        panel.orderFrontRegardless()
        sound?.playActivate()

        let tap = KeyTap(
            onKeyDown: { [weak self] kc, flags, char in
                guard let self else { return false }
                return MainActor.assumeIsolated {
                    self.handle(kc: kc, flags: flags, char: char)
                }
            },
            onKeyUp: { [weak self] kc in
                guard let self else { return false }
                return MainActor.assumeIsolated {
                    self.handleKeyUp(kc: kc)
                }
            },
            onFlagsChanged: { [weak self] flags in
                guard let self else { return }
                MainActor.assumeIsolated {
                    self.canvas.setModifierFlags(flags)
                }
            }
        )
        guard tap.install() else {
            Log.line("grid: keytap install failed — bailing")
            panel.orderOut(nil)
            onExit()
            return false
        }
        keyTap = tap
        let (cols, rows) = cellsCount
        Log.line("grid: mode entered "
                 + "(\(cols)×\(rows) cells, maxDepth=\(maxDepth))")
        return true
    }

    /// `(cols, rows)` to subdivide with. `--grid` (maxDepth == 1)
    /// uses `gridCols × gridRows`; `--rgrid` (maxDepth > 1) uses
    /// `gridRecursiveCols × gridRecursiveRows` at every level so a
    /// 3-level drill is `3×3×3` rather than `12×8×12×8×12×8`.
    private var cellsCount: (cols: Int, rows: Int) {
        if maxDepth > 1 {
            return (config.gridRecursiveCols, config.gridRecursiveRows)
        }
        return (config.gridCols, config.gridRows)
    }

    public func stop() {
        keyTap?.uninstall()
        keyTap = nil
        canvas.stopBorderCycle()
        canvas.clear()
        panel.orderOut(nil)
        hints = []
        typed = ""
        depth = 1
        peeking = false
        frameStack.removeAll(keepingCapacity: false)
        currentFrame = .zero
        Log.line("grid: mode exited")
    }

    /// Rebuild `hints` from `currentFrame`. Called on entry +
    /// after every drill / pop so labels track the new rect.
    /// The cell grid keeps its `cols × rows` density at every
    /// level (so 12×8 cells per level × 3 levels of subdivision
    /// = 288 effective addressable points).
    private func rebuildHints() {
        let (cols, rows) = cellsCount
        let cells = Self.buildCells(
            unionFrame: currentFrame, cols: cols, rows: rows)
        hints = Labeler.assign(
            elements: cells,
            alphabet: config.alphabet,
            // Center-priority makes intuitive sense here too — the
            // closest-to-current-frame-center cell gets the
            // shortest / easiest label.
            prioritiseCenter: config.prioritiseCenter,
            screenSize: currentFrame.size)
        typed = ""
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

        // Hold-to-peek: bare press orderOuts the panel so the user
        // can see the UI underneath the grid cells; keyUp restores.
        // Modifier-held space is reserved for the existing
        // "click center at current depth" action (handled below),
        // so peek only fires when no modifiers are held.
        let bare = !flags.contains(.maskCommand)
            && !flags.contains(.maskAlternate)
            && !flags.contains(.maskShift)
        if let peekKC = peekKeyCode, kc == peekKC, bare {
            if !peeking {
                peeking = true
                panel.orderOut(nil)
            }
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
        // Return / KeypadEnter — terminal click at center of the
        // current frame (M4-β). Lets the user say "good enough,
        // click here" at any depth without finishing the recursion.
        // Action mods apply (Shift → right click, Cmd → warp only,
        // …). Space was an alias historically — it now drives
        // hold-to-peek (handled above) for consistency with hint
        // mode's `[overlay].peek-key`.
        if kc == 36 || kc == 76 {       // Return, KeypadEnter
            fireAtCenter(of: currentFrame,
                         label: "center@depth=\(depth)",
                         flags: flags)
            return true
        }
        // Backspace — pop one drill level if we have one. At depth
        // 1 (root grid) it drops the last typed character instead,
        // matching the existing edit-as-you-go behaviour for
        // two-letter labels.
        if kc == 51 {
            if !frameStack.isEmpty {
                currentFrame = frameStack.removeLast()
                depth -= 1
                rebuildHints()
                canvas.present(hints: hints, typed: typed)
                Log.line("grid: popped to depth=\(depth)")
            } else if !typed.isEmpty {
                typed.removeLast()
                canvas.present(hints: filtered(), typed: typed)
            }
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
            resolve(hint: surviving[0], flags: flags)
            return true
        }
        // Exact match wins immediately (covers the "two-letter
        // label resolved" case).
        if let resolved = Labeler.resolve(hints: hints, keys: typed) {
            resolve(hint: resolved, flags: flags)
            return true
        }
        canvas.present(hints: surviving, typed: typed)
        return true
    }

    /// Decision point on a label resolve: drill into the picked
    /// cell (when more depth budget remains) OR fire the terminal
    /// click. Modifier flags ride along for the click case; on
    /// drill they're ignored (the click hasn't happened yet — only
    /// the final keystroke's modifiers matter).
    private func resolve(hint: Hint, flags: CGEventFlags) {
        if depth < maxDepth {
            frameStack.append(currentFrame)
            currentFrame = hint.element.frame
            depth += 1
            rebuildHints()
            // Clear first so the appear-effect fires fresh on each
            // drill — without `clear()`, `present()` sees the
            // previous pill set and skips the entrance animation.
            canvas.clear()
            canvas.present(hints: hints, typed: typed)
            Log.line("grid: drill to depth=\(depth) "
                     + "frame=\(OverlayCoords.rectString(currentFrame))")
            return
        }
        // Out of depth budget — fire the terminal action at the
        // picked cell's center.
        fire(hint: hint, flags: flags)
    }

    private func filtered() -> [Hint] {
        Labeler.filter(hints: hints, prefix: typed)
    }

    /// Resolve modifier flags → grid action and dispatch at the
    /// picked cell's center.
    private func fire(hint: Hint, flags: CGEventFlags) {
        fireAtCenter(of: hint.element.frame,
                     label: hint.keys,
                     flags: flags)
    }

    /// Shared terminal action: warp + click at the center of `rect`.
    /// Action mapping precedence: Cmd+Shift > Cmd > Shift > bare.
    /// Used both by `fire(hint:)` (label-driven click at the picked
    /// cell) and by `space` / `Enter` (mid-recursion "good enough,
    /// click here" — `rect = currentFrame`).
    private func fireAtCenter(
        of rect: CGRect, label: String, flags: CGEventFlags
    ) {
        let cmd = flags.contains(.maskCommand)
        let shift = flags.contains(.maskShift)
        let action: GridAction
        if cmd && shift           { action = .leftClickContinuous }
        else if cmd               { action = .warpOnly }
        else if shift             { action = .rightClick }
        else                      { action = .leftClick }

        sound?.playMatch()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        dispatch(action: action, at: center, label: label)

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

    /// Empty / unknown name → peek disabled (nil). Mirrors the
    /// `OverlayWindow.resolvePeekKeyCode` behaviour: silent fall-
    /// back per typo-tolerance.
    private static func resolvePeekKeyCode(_ name: String) -> CGKeyCode? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let kc = HotkeyMonitor.keyCode(for: trimmed) {
            return CGKeyCode(kc)
        }
        return nil
    }

    /// keyUp from the CGEventTap. Only one peek-shaped concern:
    /// when the user releases the peek key, restore the panel.
    /// Swallow the keyUp in that case so an unmatched keyUp doesn't
    /// leak into the focused app (whose keyDown was also swallowed).
    private func handleKeyUp(kc: CGKeyCode) -> Bool {
        if peeking, let peekKC = peekKeyCode, kc == peekKC {
            peeking = false
            panel.orderFrontRegardless()
            return true
        }
        return false
    }
}

// Note: `GridCanvas` (a separate NSView for grid pill rendering)
// was retired when GridMode adopted `OverlayCanvas` directly —
// theme palette, pill shape, appear / match / unmatch / narrow
// effects, border cycle, and modifier badge now flow through the
// same canvas hint mode uses. See `OverlayCanvas(placement:
// .elementCenter)` in `init` above.

// Borderless overlay panel that paints one hint pill per visible
// element + intercepts every keyDown while hint mode is up. Lives
// in the macOS adapter, not a separate View module — perch has a
// single on-screen surface and Core stays UI-free (same reasoning
// stroke uses for `GestureOverlay`).
//
// Lifecycle:
//   show(hints:cfg:onResolve:onCancel:)   activate, install local
//                                          keyDown monitor, redraw
//   redraw(filtered:)                      called after every typed
//                                          character to refresh the
//                                          surviving pills
//   hide()                                 deactivate, remove monitor

import AppKit
import CoreGraphics
import Foundation
import PerchCore

@MainActor
public final class OverlayWindow {

    private let panel: NSPanel
    private let contentView: OverlayContentView
    private var monitor: Any?
    private var hints: [Hint] = []
    private var typed = ""
    private var onResolve: ((Hint) -> Void)?
    private var onCancel: (() -> Void)?
    private var config: PerchConfig

    public init(config: PerchConfig) {
        self.config = config

        // NSPanel rather than NSWindow because non-activating
        // panels do not steal focus from the frontmost app — perch
        // needs that frontmost app to remain key so AXPress works
        // immediately on dismissal.
        let frame = NSScreen.main?.frame ?? .zero
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

        let cv = OverlayContentView(frame: frame, config: config)
        p.contentView = cv
        self.panel = p
        self.contentView = cv
    }

    public func updateConfig(_ cfg: PerchConfig) {
        self.config = cfg
        contentView.updateConfig(cfg)
        contentView.needsDisplay = true
    }

    /// Show the overlay with the given hints. `onResolve` fires when
    /// the user types a unique label. `onCancel` fires on Esc / on a
    /// keypress that doesn't match any label prefix.
    public func show(
        hints: [Hint],
        onResolve: @escaping (Hint) -> Void,
        onCancel: @escaping () -> Void
    ) {
        guard !hints.isEmpty else { onCancel(); return }
        self.hints = hints
        self.typed = ""
        self.onResolve = onResolve
        self.onCancel = onCancel

        // Cover whichever screen is currently key, fall back to
        // main. MVP: single-screen — multi-monitor is a stretch
        // goal (see CLAUDE.md).
        if let screen = NSScreen.main {
            panel.setFrame(screen.frame, display: false)
            contentView.frame = NSRect(origin: .zero, size: screen.frame.size)
            contentView.screenFrame = screen.frame
        }

        contentView.set(hints: hints, typed: typed)
        panel.orderFrontRegardless()

        // A LOCAL monitor would only fire when our panel is key,
        // which it isn't (we deliberately don't activate). A
        // GLOBAL monitor wouldn't let us swallow the event. The
        // installed monitor in `addLocalMonitorForEvents` works
        // because perch transiently becomes the active app
        // (NSApp.activate(...) below) only during hint mode.
        NSApp.activate(ignoringOtherApps: true)
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: .keyDown
        ) { [weak self] event in
            guard let self else { return event }
            self.handleKeyDown(event)
            return nil       // swallow — don't pass to the focused app
        }
    }

    public func hide() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        panel.orderOut(nil)
        hints = []
        typed = ""
        onResolve = nil
        onCancel = nil
    }

    // MARK: - Key handling

    private func handleKeyDown(_ event: NSEvent) {
        // Esc — cancel.
        if event.keyCode == 53 {
            let cb = onCancel
            hide()
            cb?()
            return
        }
        // Backspace — drop the last typed character.
        if event.keyCode == 51 {
            if !typed.isEmpty { typed.removeLast() }
            contentView.set(hints: filtered(), typed: typed)
            return
        }

        guard let chars = event.charactersIgnoringModifiers?.lowercased(),
              let ch = chars.first,
              ch.isLetter
        else {
            // Non-letter keypress: cancel rather than confuse the user.
            let cb = onCancel
            hide()
            cb?()
            return
        }
        typed.append(ch)

        let surviving = filtered()
        if surviving.isEmpty {
            let cb = onCancel
            hide()
            cb?()
            return
        }
        // Auto-click on unique candidate (configurable).
        if config.autoClickOnUnique, surviving.count == 1 {
            let only = surviving[0]
            let cb = onResolve
            hide()
            cb?(only)
            return
        }
        // Exact match wins immediately.
        if let resolved = Labeler.resolve(hints: hints, keys: typed) {
            let cb = onResolve
            hide()
            cb?(resolved)
            return
        }
        contentView.set(hints: surviving, typed: typed)
    }

    private func filtered() -> [Hint] {
        Labeler.filter(hints: hints, prefix: typed)
    }
}


/// View that paints the dim layer + each hint pill. Recreated on
/// every overlay show; mutated by `set(hints:typed:)` while up.
@MainActor
private final class OverlayContentView: NSView {

    private var hints: [Hint] = []
    private var typed = ""
    private var config: PerchConfig
    var screenFrame: CGRect = .zero

    init(frame: NSRect, config: PerchConfig) {
        self.config = config
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool {
        // Cocoa default is bottom-left origin. AX gives us
        // top-left frames, so flipping the view keeps the two
        // coord systems aligned and the per-hint translate stays
        // a single screen-Y subtraction.
        true
    }

    func updateConfig(_ cfg: PerchConfig) { self.config = cfg }

    func set(hints: [Hint], typed: String) {
        self.hints = hints
        self.typed = typed
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Dim layer.
        if config.overlayDim > 0 {
            ctx.setFillColor(
                CGColor(srgbRed: 0, green: 0, blue: 0,
                        alpha: CGFloat(config.overlayDim)))
            ctx.fill(bounds)
        }

        let bgColor = nsColor(hex: config.overlayBackground)
            ?? NSColor.systemYellow
        let fgColor = nsColor(hex: config.overlayForeground)
            ?? NSColor.black
        let font = NSFont.monospacedSystemFont(
            ofSize: CGFloat(config.overlayFontSize), weight: .bold)

        let typedAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.systemRed,
        ]
        let pendingAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fgColor,
        ]

        for h in hints {
            // Convert AX screen frame to our view-local coords.
            let x = h.element.frame.origin.x - screenFrame.origin.x
            let y = h.element.frame.origin.y - screenFrame.origin.y
            let pillH = font.pointSize * 1.6
            let padding: CGFloat = 4
            // Measure label width.
            let attr = NSAttributedString(
                string: h.keys.uppercased(), attributes: pendingAttrs)
            let labelW = attr.size().width
            let pillW = labelW + padding * 2

            let pill = NSRect(x: x, y: y, width: pillW, height: pillH)
            ctx.setFillColor(bgColor.cgColor)
            let path = CGPath(
                roundedRect: pill, cornerWidth: 3,
                cornerHeight: 3, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()

            // Render the label in two colors: already-typed prefix
            // in red, remaining keys in the configured foreground.
            let upper = h.keys.uppercased()
            let typedUpper = typed.uppercased()
            let typedPart = upper.hasPrefix(typedUpper)
                ? String(upper.prefix(typedUpper.count)) : ""
            let restPart = String(upper.dropFirst(typedPart.count))

            var px = pill.origin.x + padding
            let py = pill.origin.y + (pillH - font.pointSize) / 2 - 1

            if !typedPart.isEmpty {
                let s = NSAttributedString(
                    string: typedPart, attributes: typedAttrs)
                s.draw(at: NSPoint(x: px, y: py))
                px += s.size().width
            }
            if !restPart.isEmpty {
                let s = NSAttributedString(
                    string: restPart, attributes: pendingAttrs)
                s.draw(at: NSPoint(x: px, y: py))
            }
        }
    }

    private func nsColor(hex: String) -> NSColor? {
        var t = hex
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green:    CGFloat((v >> 8) & 0xFF) / 255,
            blue:     CGFloat(v & 0xFF) / 255,
            alpha: 1)
    }
}

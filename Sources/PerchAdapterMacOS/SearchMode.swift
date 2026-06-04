// Search mode — type to fuzzy-match `AXTitle` substrings across
// every clickable element in the frontmost app, then press a
// digit (1-9) to fire the action against the corresponding match.
//
// Why a separate mode: hint-mode's "type a label" UX hits a hard
// ceiling on apps with thousands of clickables (Xcode, Logic) —
// the alphabet runs out before you find the thing you wanted.
// Search mode flips the model: name what you want, perch shows
// you only the matches.
//
// Bindings (active while search mode is up):
//   any letter / digit / punctuation / space  ⇒ append to query
//   backspace                                 ⇒ drop last char
//   1..9 PROVIDED there's a current match     ⇒ activate match[N-1]
//                                              (default `.press`,
//                                              modifier→action mode
//                                              same as hint mode)
//   enter                                     ⇒ activate match[0]
//   esc / configured cancel key               ⇒ exit silently
//
// 1..9 disambiguation: when the user has narrowed enough that
// they want to PICK, they press a digit. To keep query-entry of
// digits possible too, we resolve digit→match ONLY when there's
// a non-empty current match list; if the matches are empty the
// digit is treated as a query character.
//
// Visual: a centered "🔍 query" pill at the top of the screen +
// one digit-labelled pill per match, positioned over the AX
// frame of each. Reuses the visual recipe from OverlayWindow.

import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import PerchCore

@MainActor
public final class SearchMode {

    private let source: AXUIElementSource
    private let config: PerchConfig
    private let onResolve: (UIElement, HintAction) -> Void
    private let onExit: () -> Void

    private let panel: NSPanel
    private let canvas: SearchCanvas
    private var keyTap: KeyTap?
    private var cancelKeyCode: CGKeyCode = 53        // Esc

    /// Cached AX enumeration — captured once on entry so per-keystroke
    /// filtering doesn't re-walk the AX tree (which is slow on big
    /// apps and would re-shuffle ids).
    private var elements: [UIElement] = []
    private var query: String = ""
    private var matches: [UIElement] = []
    private static let topN = 9

    public init(
        source: AXUIElementSource,
        config: PerchConfig,
        onResolve: @escaping (UIElement, HintAction) -> Void,
        onExit: @escaping () -> Void
    ) {
        self.source = source
        self.config = config
        self.onResolve = onResolve
        self.onExit = onExit
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
        let cv = SearchCanvas(
            frame: NSRect(origin: .zero, size: frame.size),
            config: config)
        cv.unionFrame = frame
        cv.primaryHeight = OverlayCoords.primaryHeight()
        p.contentView = cv
        self.panel = p
        self.canvas = cv
    }

    @discardableResult
    public func start() -> Bool {
        elements = source.enumerate()
        let union = OverlayCoords.unionFrame()
        panel.setFrame(union, display: false)
        canvas.frame = NSRect(origin: .zero, size: union.size)
        canvas.unionFrame = union
        canvas.primaryHeight = OverlayCoords.primaryHeight()
        recompute()
        panel.orderFrontRegardless()

        let tap = KeyTap { [weak self] kc, flags, char in
            guard let self else { return false }
            return MainActor.assumeIsolated {
                self.handle(kc: kc, flags: flags, char: char)
            }
        }
        guard tap.install() else {
            Log.line("search: keytap install failed — bailing")
            panel.orderOut(nil)
            onExit()
            return false
        }
        keyTap = tap
        Log.line("search: mode entered (\(elements.count) elements)")
        return true
    }

    public func stop() {
        keyTap?.uninstall()
        keyTap = nil
        panel.orderOut(nil)
        elements.removeAll(keepingCapacity: true)
        matches.removeAll(keepingCapacity: true)
        query = ""
        Log.line("search: mode exited")
    }

    // MARK: - Key handling

    private func handle(
        kc: CGKeyCode, flags: CGEventFlags, char: String
    ) -> Bool {
        // Esc — exit silently.
        if kc == cancelKeyCode {
            stop()
            onExit()
            return true
        }
        // Ctrl-anything → exit + pass through.
        if flags.contains(.maskControl) {
            stop()
            onExit()
            return false
        }
        // Enter / Return — pick the first match if any.
        if kc == 36 || kc == 76 {           // kVK_Return, kVK_ANSI_KeypadEnter
            if let first = matches.first {
                fire(first, flags: flags)
            }
            return true
        }
        // Backspace.
        if kc == 51 {
            if !query.isEmpty { query.removeLast() }
            recompute()
            return true
        }

        guard let ch = char.first else { return true }
        // Digit 1..9 with non-empty matches → pick.
        if let d = ch.wholeNumberValue, d >= 1, d <= 9,
           !matches.isEmpty, d <= matches.count {
            fire(matches[d - 1], flags: flags)
            return true
        }
        // Otherwise append to query.
        if ch.isLetter || ch.isNumber || ch.isPunctuation
            || ch.isSymbol || ch == " " {
            query.append(ch)
            recompute()
            return true
        }
        // Unknown key — let it through to be safe.
        stop()
        onExit()
        return false
    }

    private func fire(_ element: UIElement, flags: CGEventFlags) {
        let action: HintAction
        // Modifier precedence mirrors OverlayWindow.actionFor — keep
        // them in sync. Cmd+Shift wins over plain Cmd so the more
        // specific combo (.pressContinuous) doesn't get masked.
        if flags.contains(.maskCommand) && flags.contains(.maskShift) {
            action = .pressContinuous
        } else if flags.contains(.maskCommand)   { action = .copyTitle }
        else if flags.contains(.maskAlternate)   { action = .focus }
        else if flags.contains(.maskShift)       { action = .rightClick }
        else { action = .press }
        stop()
        onResolve(element, action)
    }

    private func recompute() {
        let q = query.lowercased()
        // Split on whitespace into AND'd substring tokens.
        //   "f b"  matches "Foo Bar" and "Foo's Big Idea", not
        //          "foobar" (no second token to find).
        //   "foo"  is one token — equivalent to the previous
        //          single-substring behaviour.
        // `split(whereSeparator:)` drops empty tokens, so a
        // trailing space doesn't introduce an unmatchable "".
        let tokens = q.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        if tokens.isEmpty {
            matches = Array(elements.prefix(Self.topN))
        } else {
            matches = elements
                .filter { e in
                    let label = e.label.lowercased()
                    return tokens.allSatisfy { label.contains($0) }
                }
                .prefix(Self.topN)
                .map { $0 }
        }
        canvas.present(query: query, matches: matches)
    }

    private static func resolveCancelKeyCode(_ name: String) -> CGKeyCode {
        if let kc = HotkeyMonitor.keyCode(for: name) {
            return CGKeyCode(kc)
        }
        return 53
    }
}


// MARK: - SearchCanvas (NSView)

/// Minimal canvas for search mode: paints the query strip at top
/// centre + numbered pills over each AX match. Doesn't share with
/// OverlayCanvas (the hint-mode canvas) to keep the visual rules
/// for each mode isolated — search mode never needs scale-in,
/// matched-prefix glow, or miss-flash; hint mode never needs the
/// query strip.
@MainActor
private final class SearchCanvas: NSView {

    /// Same conversion fields as `OverlayCanvas`. See its docstring
    /// for the AX→canvas formula and why both `unionFrame` and
    /// `primaryHeight` are needed.
    var unionFrame: CGRect = .zero
    var primaryHeight: CGFloat = 0
    private let config: PerchConfig
    private var query: String = ""
    private var matches: [UIElement] = []

    init(frame frameRect: NSRect, config: PerchConfig) {
        self.config = config
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func present(query: String, matches: [UIElement]) {
        self.query = query
        self.matches = matches
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let accent = SearchCanvas.accent(config.overlayAccent)
        let font = NSFont.monospacedSystemFont(
            ofSize: CGFloat(config.overlayFontSize), weight: .semibold)
        let small = NSFont.monospacedSystemFont(
            ofSize: CGFloat(config.overlayFontSize) - 1, weight: .regular)

        // 1) Query strip at top centre.
        let label = "🔍  " + (query.isEmpty ? "search…" : query)
        let attr = NSAttributedString(string: label, attributes: [
            .font: font, .foregroundColor: NSColor.white])
        let textSize = attr.size()
        let stripW = ceil(textSize.width) + 28
        let stripH = ceil(font.boundingRectForFont.height) + 18
        let stripX = (bounds.width - stripW) / 2
        let stripY: CGFloat = 24
        let stripRect = CGRect(
            x: stripX, y: stripY, width: stripW, height: stripH)
        let stripPath = NSBezierPath(
            roundedRect: stripRect, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.7).setFill()
        stripPath.fill()
        accent.withAlphaComponent(0.9).setStroke()
        stripPath.lineWidth = 2
        stripPath.stroke()
        attr.draw(at: NSPoint(
            x: stripX + 14,
            y: stripY + (stripH - textSize.height) / 2 - 1))

        // 2) Numbered pills over each match.
        for (i, e) in matches.enumerated() {
            let digit = "\(i + 1)"
            let digitAttr = NSAttributedString(string: digit, attributes: [
                .font: font, .foregroundColor: NSColor.white])
            let titleAttr = NSAttributedString(
                string: " " + (e.label.isEmpty
                                ? (e.role.lowercased())
                                : e.label).prefix(32).description,
                attributes: [.font: small,
                             .foregroundColor: NSColor.white])
            let combined = NSMutableAttributedString()
            combined.append(digitAttr)
            combined.append(titleAttr)
            let tSize = combined.size()
            let w = ceil(tSize.width) + 20
            let h = ceil(font.boundingRectForFont.height) + 14

            let local = OverlayCoords.canvasLocal(
                cg: e.frame.origin,
                unionFrame: unionFrame,
                primaryHeight: primaryHeight)
            var x = local.x
            var y = local.y
            x = min(max(x, 6), bounds.width - w - 6)
            y = min(max(y, 6), bounds.height - h - 6)
            let r = CGRect(x: x, y: y, width: w, height: h)
            let p = NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10)
            accent.withAlphaComponent(0.85).setFill()
            p.fill()
            NSColor.white.withAlphaComponent(0.4).setStroke()
            p.lineWidth = 1
            p.stroke()
            combined.draw(at: NSPoint(
                x: r.origin.x + 10,
                y: r.origin.y + (h - tSize.height) / 2 - 1))
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

// Screen-geometry helpers shared by every overlay surface
// (`OverlayWindow`, `SearchMode`, future `--region` etc.).
//
// macOS exposes window/element geometry across two coordinate
// systems that don't agree on Y direction OR on origin:
//
//   - Cocoa (NSView / NSWindow / NSScreen): Y-up, origin at
//     bottom-left of the PRIMARY display
//   - CG / AX (CGEvent / AXUIElement positions): Y-down, origin
//     at top-left of the PRIMARY display
//
// AX delivers element positions in CG coords; we paint into an
// `isFlipped = true` canvas covering a Cocoa-coord panel. The
// helpers here capture the conversion glue so it lives in exactly
// one place — every overlay just calls `OverlayCoords.unionFrame()`
// + `OverlayCoords.primaryHeight()` at show() time and applies the
// `canvasCGTopY` documented in `OverlayCoords.canvasY(forCG:in:primaryHeight:)`.

import AppKit
import CoreGraphics

enum OverlayCoords {

    /// Union of every connected screen's frame in Cocoa global
    /// coordinates. Use this for the overlay panel's frame — a
    /// pill for a window on a secondary display needs canvas
    /// pixels to land on, and `NSScreen.main.frame` alone doesn't
    /// cover them.
    static func unionFrame() -> CGRect {
        let screens = NSScreen.screens
        guard var u = screens.first?.frame else {
            return NSScreen.main?.frame ?? .zero
        }
        for s in screens.dropFirst() { u = u.union(s.frame) }
        return u
    }

    /// Height of the screen at Cocoa origin (0, 0) — that's the
    /// "primary" screen CG global coords are anchored to. Falls
    /// back to `NSScreen.main`'s height, then 0. Required for the
    /// Y-axis side of the AX → canvas conversion below.
    static func primaryHeight() -> CGFloat {
        NSScreen.screens
            .first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
    }

    /// Convert a CG global position (top-left primary) to a
    /// canvas-local position for an `isFlipped = true` view that
    /// covers `unionFrame` in Cocoa coords.
    ///
    ///   canvas_x = CG_x − unionFrame.minX
    ///   canvas_y = CG_y − (primaryHeight − unionFrame.maxY)
    ///
    /// When the primary IS the topmost screen, `primaryHeight −
    /// unionFrame.maxY` is 0 and the formula collapses to the
    /// single-screen identity — so this is a strict superset of
    /// the trivial case.
    static func canvasLocal(
        cg point: CGPoint,
        unionFrame: CGRect,
        primaryHeight: CGFloat
    ) -> CGPoint {
        let topY = primaryHeight - unionFrame.maxY
        return CGPoint(
            x: point.x - unionFrame.minX,
            y: point.y - topY)
    }

    /// Compact `(x,y W×H)` formatter for the diagnostic log so
    /// `ax: bounds cg=… ax=… → filter=…` lines stay one line and
    /// grep-friendly. Used by `AXSource` + the overlay show()
    /// path; keep the format stable so log parsers don't break.
    static func rectString(_ r: CGRect) -> String {
        if r.isNull { return "null" }
        return "(\(Int(r.minX)),\(Int(r.minY)) "
            + "\(Int(r.width))×\(Int(r.height)))"
    }
}

#!/usr/bin/swift
//
// Generate Perch.icns from scratch using CoreGraphics — no external
// art tools required. Renders the icon at the 10 sizes macOS expects
// in an .iconset directory, then `iconutil -c icns` rolls it up.
// Run from the repo root via `scripts/make-icon.sh` (or directly:
// `swift run`).
//
// Design: a flat geometric "perched bird" silhouette on a yellow
// squircle. "Perch" literally means a branch a bird rests on, so the
// icon is the brand name in pictogram form. Composition follows the
// Twitter-bird family of icons (flat, no outline, composed of
// overlapping geometric primitives), with a horizontal branch under
// the bird's feet that doubles as the keyboard "home row" guide.
//
// Colors:
//   bg     #fde047 → #facc15  (overlay pill bg, gradient for depth)
//   ink    #1f2937              (overlay foreground; bird silhouette)
//
// A bright yellow perimeter prevents the icon from "framing dark"
// against dark Docks/wallpapers — the previous dark-squircle version
// dropped visibility there.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Output sizes
let sizes: [(label: String, dim: Int)] = [
    ("16x16",      16),
    ("16x16@2x",   32),
    ("32x32",      32),
    ("32x32@2x",   64),
    ("128x128",   128),
    ("128x128@2x", 256),
    ("256x256",   256),
    ("256x256@2x", 512),
    ("512x512",   512),
    ("512x512@2x", 1024),
]

// MARK: - Colors
// Brand yellow (matches [overlay].background = #fde047 with a slight
// darker bottom #facc15 for a subtle gradient).
private let bgTop    = CGColor(srgbRed: 0xfd/255, green: 0xe0/255, blue: 0x47/255, alpha: 1)
private let bgBottom = CGColor(srgbRed: 0xfa/255, green: 0xcc/255, blue: 0x15/255, alpha: 1)
// Dark slate ink (matches [overlay].foreground = #1f2937).
private let inkFG    = CGColor(srgbRed: 0x1f/255, green: 0x29/255, blue: 0x37/255, alpha: 1)
// Eye highlight — same yellow as bg so it reads as negative space
// when the bird overlaps it.
private let eyeFG    = CGColor(srgbRed: 0xfd/255, green: 0xe0/255, blue: 0x47/255, alpha: 1)

// MARK: - Rendering

func render(side dim: CGFloat) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: Int(dim), height: Int(dim),
        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("CGContext alloc failed at \(dim)") }

    // Squircle background (Apple template ratio ≈22.37%).
    let rect = CGRect(x: 0, y: 0, width: dim, height: dim)
    let r = dim * 0.2237
    let bgPath = CGPath(roundedRect: rect, cornerWidth: r,
                        cornerHeight: r, transform: nil)
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: cs,
        colors: [bgTop, bgBottom] as CFArray,
        locations: [0, 1]
    )!
    // Y-up bitmap: start at top (y == dim), end at bottom.
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: dim),
        end:   CGPoint(x: 0, y: 0),
        options: [])
    ctx.restoreGState()

    drawBird(ctx: ctx, dim: dim)

    guard let image = ctx.makeImage() else {
        fatalError("makeImage failed at \(dim)")
    }
    return image
}

/// Draw the perched-bird silhouette + branch. All coordinates are
/// fractions of `dim` (CG y-up) so the design scales identically at
/// every iconset size.
func drawBird(ctx: CGContext, dim: CGFloat) {
    ctx.setFillColor(inkFG)

    // ─── Branch ─────────────────────────────────────────────────
    // Pill-shaped horizontal bar. Doubles as the "home row" guide
    // visual nod that survived from the previous design.
    let branchY = dim * 0.18
    let branchH = dim * 0.030
    let branchPath = CGPath(
        roundedRect: CGRect(
            x: dim * 0.10, y: branchY,
            width: dim * 0.80, height: branchH),
        cornerWidth: branchH / 2,
        cornerHeight: branchH / 2,
        transform: nil)
    ctx.addPath(branchPath)
    ctx.fillPath()

    // ─── Legs ───────────────────────────────────────────────────
    // Two thin verticals from the branch up to the body's bottom.
    let legTop = branchY + branchH * 0.5
    let legBottom = legTop
    let legH = dim * 0.085
    let legW = dim * 0.028
    ctx.fill(CGRect(x: dim * 0.42, y: legBottom, width: legW, height: legH))
    ctx.fill(CGRect(x: dim * 0.54, y: legBottom, width: legW, height: legH))

    // ─── Body ───────────────────────────────────────────────────
    // Egg-shape, tilted slightly so the head sits higher than the
    // tail. Drawn via a rotated ellipse.
    ctx.saveGState()
    ctx.translateBy(x: dim * 0.48, y: dim * 0.46)
    ctx.rotate(by: 0.18)  // ~10° counterclockwise — head-up posture
    let bodyRect = CGRect(
        x: -dim * 0.23, y: -dim * 0.16,
        width: dim * 0.46, height: dim * 0.32)
    ctx.fillEllipse(in: bodyRect)
    ctx.restoreGState()

    // ─── Tail ───────────────────────────────────────────────────
    // Triangular wedge extending back-and-up from the body.
    let tailPath = CGMutablePath()
    tailPath.move(to:    CGPoint(x: dim * 0.32, y: dim * 0.44))
    tailPath.addLine(to: CGPoint(x: dim * 0.08, y: dim * 0.62))
    tailPath.addLine(to: CGPoint(x: dim * 0.18, y: dim * 0.32))
    tailPath.closeSubpath()
    ctx.addPath(tailPath)
    ctx.fillPath()

    // ─── Wing ───────────────────────────────────────────────────
    // A leaf-shaped patch slightly offset on the body — gives the
    // silhouette dimension without an outline.
    // Drawn in the *background* yellow so it cuts a subtle wing
    // shape out of the body fill.
    ctx.setFillColor(bgTop)
    let wingPath = CGMutablePath()
    wingPath.move(to:    CGPoint(x: dim * 0.34, y: dim * 0.46))
    wingPath.addQuadCurve(
        to:      CGPoint(x: dim * 0.58, y: dim * 0.38),
        control: CGPoint(x: dim * 0.46, y: dim * 0.56))
    wingPath.addQuadCurve(
        to:      CGPoint(x: dim * 0.34, y: dim * 0.46),
        control: CGPoint(x: dim * 0.46, y: dim * 0.34))
    wingPath.closeSubpath()
    ctx.addPath(wingPath)
    ctx.fillPath()

    // Restore ink for remaining bird parts.
    ctx.setFillColor(inkFG)

    // ─── Head ───────────────────────────────────────────────────
    // Circle overlapping the body's upper-right shoulder.
    let headR = dim * 0.125
    let headC = CGPoint(x: dim * 0.66, y: dim * 0.62)
    ctx.fillEllipse(in: CGRect(
        x: headC.x - headR, y: headC.y - headR,
        width: headR * 2, height: headR * 2))

    // ─── Beak ───────────────────────────────────────────────────
    // Short triangle pointing right from the head.
    let beakPath = CGMutablePath()
    beakPath.move(to:    CGPoint(x: dim * 0.76, y: dim * 0.66))
    beakPath.addLine(to: CGPoint(x: dim * 0.92, y: dim * 0.61))
    beakPath.addLine(to: CGPoint(x: dim * 0.76, y: dim * 0.56))
    beakPath.closeSubpath()
    ctx.addPath(beakPath)
    ctx.fillPath()

    // ─── Eye ────────────────────────────────────────────────────
    // A tiny dot of bg color punched through the head.
    // Skipped below 64px — at small sizes the dot turns into noise.
    if dim >= 64 {
        ctx.setFillColor(eyeFG)
        let eyeR = max(dim * 0.020, 1)
        let eyeC = CGPoint(x: dim * 0.71, y: dim * 0.66)
        ctx.fillEllipse(in: CGRect(
            x: eyeC.x - eyeR, y: eyeC.y - eyeR,
            width: eyeR * 2, height: eyeR * 2))
    }
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
    }
    try data.write(to: url)
}

// MARK: - main

let fm = FileManager.default
let iconset = "Perch.iconset"
try? fm.removeItem(atPath: iconset)
try fm.createDirectory(atPath: iconset,
                       withIntermediateDirectories: true)

for (label, dim) in sizes {
    let image = render(side: CGFloat(dim))
    let path = "\(iconset)/icon_\(label).png"
    try writePNG(image, to: URL(fileURLWithPath: path))
    print("  ✓ \(label.padding(toLength: 12, withPad: " ", startingAt: 0)) → \(path) (\(dim)px)")
}

print("\nwrote \(iconset) — run `iconutil -c icns \(iconset) -o Perch.icns` to package")

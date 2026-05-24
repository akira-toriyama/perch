#!/usr/bin/swift
//
// Generate Perch.icns from scratch using CoreGraphics — no external
// art tools required. Renders the icon at the 10 sizes macOS expects
// in an .iconset directory, then `iconutil -c icns` rolls it up.
// Run from the repo root via `scripts/make-icon.sh` (or directly:
// `swift run`).
//
// Design: a single hint pill labelled "P" sitting on a faint
// horizontal "home row" guideline, on a yellow squircle. The yellow
// matches the overlay's `[overlay].background` so the app icon and
// the live hint pills share an identity. The home-row guide is the
// visual nod to the keyboard row perch biases its labels toward.

import AppKit
import CoreGraphics
import Foundation

// MARK: - Output sizes
// Standard macOS .iconset members. Listing both the 1x and the @2x
// physical size lets iconutil pick the right entry on every display.
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
// Yellow gradient — top → bottom. Matches the overlay's pill bg
// (#fde047) so app icon + live hints read as one identity. The
// bottom is a slightly darker tint of the same hue (#f59e0b) so
// the gradient reads as depth, not a second color.
private let bgTop    = CGColor(srgbRed: 0xfd/255, green: 0xe0/255, blue: 0x47/255, alpha: 1)
private let bgBottom = CGColor(srgbRed: 0xf5/255, green: 0x9e/255, blue: 0x0b/255, alpha: 1)
// Dark slate, matching [overlay].foreground = #1f2937.
private let inkFG    = CGColor(srgbRed: 0x1f/255, green: 0x29/255, blue: 0x37/255, alpha: 1)
// Faint home-row guide.
private let guideFG  = CGColor(srgbRed: 0x1f/255, green: 0x29/255, blue: 0x37/255, alpha: 0.25)

// MARK: - Rendering

/// Render the icon at `side` × `side` px and return a CGImage.
func render(side dim: CGFloat) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: Int(dim), height: Int(dim),
        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("CGContext alloc failed at \(dim)") }

    // Squircle background. The corner-radius ratio matches Apple's
    // own app-icon template (≈22.37% of the side).
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
    // CGContext bitmaps are Y-up: start the gradient at the *top*
    // (y == dim) and walk down to y == 0.
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: dim),
        end:   CGPoint(x: 0, y: 0),
        options: [])
    ctx.restoreGState()

    // Home-row guideline — a faint horizontal line across the lower
    // third (Y is up, so "lower visually" = smaller Y). It's the
    // baseline the hint pill sits on, evoking the keyboard's home row.
    let guideY = dim * 0.32
    ctx.setStrokeColor(guideFG)
    ctx.setLineWidth(max(1, dim * 0.012))
    ctx.move(to: CGPoint(x: dim * 0.16, y: guideY))
    ctx.addLine(to: CGPoint(x: dim * 0.84, y: guideY))
    ctx.strokePath()

    // Hint pill — rounded rectangle "perched" on the home-row guide.
    // The pill is positioned with its bottom edge touching guideY.
    let pillW = dim * 0.48
    let pillH = dim * 0.42
    let pillX = (dim - pillW) / 2
    let pillY = guideY                      // bottom edge on the guide
    let pillR = pillH * 0.18
    let pillPath = CGPath(
        roundedRect: CGRect(x: pillX, y: pillY, width: pillW, height: pillH),
        cornerWidth: pillR, cornerHeight: pillR, transform: nil)
    ctx.setFillColor(inkFG)
    ctx.addPath(pillPath)
    ctx.fillPath()

    // "P" glyph centered in the pill — drawn as a path so we don't
    // depend on a specific font being available at build time.
    // Bold geometric P: vertical stem + a closed half-loop.
    drawP(ctx: ctx, dim: dim, pillX: pillX, pillY: pillY,
          pillW: pillW, pillH: pillH)

    guard let image = ctx.makeImage() else {
        fatalError("makeImage failed at \(dim)")
    }
    return image
}

/// Draw a stylised "P" inside a pill. All numbers are fractions of
/// `dim` so the icon scales cleanly across the 10 sizes.
func drawP(ctx: CGContext, dim: CGFloat,
           pillX: CGFloat, pillY: CGFloat,
           pillW: CGFloat, pillH: CGFloat) {
    // Layout inside the pill:
    //   stem at left third, vertical, full pill height (minus padding)
    //   loop occupies right two-thirds, top half of the pill
    let padding = dim * 0.05
    let stemW = pillW * 0.18
    let stemX = pillX + (pillW - stemW * 2.5) / 2   // slight left bias
    let stemBottom = pillY + padding
    let stemTop = pillY + pillH - padding
    let stemH = stemTop - stemBottom

    // White ink for the P (contrast against dark pill).
    let ink = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    ctx.setFillColor(ink)

    // Stem.
    ctx.fill(CGRect(x: stemX, y: stemBottom, width: stemW, height: stemH))

    // Loop: a ring fitting the top half of the pill, right of the
    // stem. Built as the difference of two ellipses (outer minus
    // inner) using even-odd fill.
    let loopOuterX = stemX + stemW * 0.9         // overlap the stem a touch
    let loopOuterY = stemBottom + stemH * 0.5    // bottom of loop = mid stem
    let loopOuterW = pillW * 0.5
    let loopOuterH = stemH * 0.5

    ctx.saveGState()
    let outer = CGPath(
        ellipseIn: CGRect(x: loopOuterX, y: loopOuterY,
                          width: loopOuterW, height: loopOuterH),
        transform: nil)
    let innerInset = min(loopOuterW, loopOuterH) * 0.26
    let inner = CGPath(
        ellipseIn: CGRect(x: loopOuterX + innerInset,
                          y: loopOuterY + innerInset,
                          width: loopOuterW - innerInset * 2,
                          height: loopOuterH - innerInset * 2),
        transform: nil)
    let ring = CGMutablePath()
    ring.addPath(outer)
    ring.addPath(inner)
    ctx.addPath(ring)
    ctx.fillPath(using: .evenOdd)
    ctx.restoreGState()
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

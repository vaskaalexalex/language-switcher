#!/usr/bin/env swift
//
// Generates Resources/AppIcon.icns with two opposing arrows (⇄) over a
// rounded-square blue gradient background. Uses pure AppKit + iconutil.
//
// Usage:
//   swift scripts/make-icon.swift <output-dir>
//
// Produces:
//   <output-dir>/AppIcon.icns
//

import AppKit
import CoreGraphics

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: make-icon.swift <output-dir>\n", stderr)
    exit(1)
}

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

let iconset = outDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// MARK: - Drawing

func renderPNG(pixelSize: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "make-icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create bitmap"])
    }

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }

    guard let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
        throw NSError(domain: "make-icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot create graphics context"])
    }
    NSGraphicsContext.current = gctx
    let ctx = gctx.cgContext
    let size = CGFloat(pixelSize)

    // Rounded-square mask (matches the macOS Big Sur+ app icon radius).
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let corner = size * 0.225
    let path = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // Background gradient (top-lighter → bottom-darker blue).
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let colors = [
        NSColor(red: 0.30, green: 0.62, blue: 1.00, alpha: 1).cgColor,
        NSColor(red: 0.12, green: 0.33, blue: 0.82, alpha: 1).cgColor
    ] as CFArray
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: 0, y: 0),
        options: []
    )

    // Soft inner highlight along the top.
    let highlight = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            NSColor.white.withAlphaComponent(0.18).cgColor,
            NSColor.white.withAlphaComponent(0.00).cgColor
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(
        highlight,
        start: CGPoint(x: 0, y: size),
        end: CGPoint(x: 0, y: size * 0.55),
        options: []
    )

    ctx.restoreGState()

    // Two opposing arrows in white: top row points right, bottom row points left.
    NSColor.white.setStroke()
    NSColor.white.setFill()
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)

    let thickness = size * 0.075
    let headSize  = size * 0.20

    drawArrow(
        ctx: ctx,
        from: CGPoint(x: size * 0.22, y: size * 0.635),
        to:   CGPoint(x: size * 0.78, y: size * 0.635),
        thickness: thickness,
        head: headSize
    )
    drawArrow(
        ctx: ctx,
        from: CGPoint(x: size * 0.78, y: size * 0.365),
        to:   CGPoint(x: size * 0.22, y: size * 0.365),
        thickness: thickness,
        head: headSize
    )

    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "png encode failed"])
    }
    return png
}

func drawArrow(ctx: CGContext, from p0: CGPoint, to p1: CGPoint, thickness: CGFloat, head: CGFloat) {
    let dx = p1.x - p0.x
    let dy = p1.y - p0.y
    let len = hypot(dx, dy)
    guard len > 0 else { return }
    let ux = dx / len
    let uy = dy / len
    // Perpendicular unit vector.
    let px = -uy
    let py = ux

    // Shaft: stroke from p0 up to just before the arrowhead base.
    ctx.setLineWidth(thickness)
    ctx.beginPath()
    ctx.move(to: p0)
    ctx.addLine(to: CGPoint(
        x: p1.x - ux * head * 0.55,
        y: p1.y - uy * head * 0.55
    ))
    ctx.strokePath()

    // Arrowhead: filled triangle.
    let base = CGPoint(x: p1.x - ux * head, y: p1.y - uy * head)
    let left = CGPoint(x: base.x + px * head * 0.55, y: base.y + py * head * 0.55)
    let right = CGPoint(x: base.x - px * head * 0.55, y: base.y - py * head * 0.55)
    ctx.beginPath()
    ctx.move(to: p1)
    ctx.addLine(to: left)
    ctx.addLine(to: right)
    ctx.closePath()
    ctx.fillPath()
}

// MARK: - Emit

let variants: [(size: Int, name: String)] = [
    (16,   "icon_16x16.png"),
    (32,   "icon_16x16@2x.png"),
    (32,   "icon_32x32.png"),
    (64,   "icon_32x32@2x.png"),
    (128,  "icon_128x128.png"),
    (256,  "icon_128x128@2x.png"),
    (256,  "icon_256x256.png"),
    (512,  "icon_256x256@2x.png"),
    (512,  "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for v in variants {
    let data = try renderPNG(pixelSize: v.size)
    let dest = iconset.appendingPathComponent(v.name)
    try data.write(to: dest)
}

let icns = outDir.appendingPathComponent("AppIcon.icns")
try? FileManager.default.removeItem(at: icns)

let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    fputs("iconutil exited with status \(proc.terminationStatus)\n", stderr)
    exit(Int32(proc.terminationStatus))
}

// Keep the .iconset alongside the .icns for debugging / future edits.
print("wrote \(icns.path)")

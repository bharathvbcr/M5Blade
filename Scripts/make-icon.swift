#!/usr/bin/env swift
//
// Renders the app icon and packs it into an .icns.
//
//   swift Scripts/make-icon.swift Resources/AppIcon.icns
//
// Uses only CoreGraphics and iconutil, both part of the OS — the icon is
// generated from code so it is reviewable in a diff and needs no binary asset
// checked into the tree.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Geometry

/// A fan blade: two spirals from the hub to the rim, narrow at the hub and
/// widest at the tip, so the rim end reads as a rounded blade rather than a
/// wedge. Sampled rather than hand-fitted to beziers — at icon sizes the
/// difference is invisible and the shape stays easy to tune.
func bladePath(center: CGPoint,
               hubRadius: CGFloat,
               outerRadius: CGFloat,
               baseAngle: CGFloat,
               sweep: CGFloat,
               maxWidth: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let steps = 48

    func point(_ radius: CGFloat, _ angle: CGFloat) -> CGPoint {
        CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    /// Blade width grows toward the rim but stays finite at the root, so the
    /// blades read as joined to the hub rather than floating around it.
    func width(_ t: CGFloat) -> CGFloat {
        maxWidth * (0.34 + 0.66 * sin(t * .pi / 2))
    }

    // Leading edge, hub -> rim.
    for i in 0...steps {
        let t = CGFloat(i) / CGFloat(steps)
        let r = hubRadius + (outerRadius - hubRadius) * t
        let a = baseAngle + sweep * t
        let p = point(r, a)
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    // Trailing edge, rim -> hub.
    for i in stride(from: steps, through: 0, by: -1) {
        let t = CGFloat(i) / CGFloat(steps)
        let r = hubRadius + (outerRadius - hubRadius) * t
        let a = baseAngle + sweep * t + width(t)
        path.addLine(to: point(r, a))
    }
    path.closeSubpath()
    return path
}

/// macOS icons sit in a rounded square with margin around it, not edge to edge.
func squirclePath(in rect: CGRect) -> CGPath {
    CGPath(roundedRect: rect,
           cornerWidth: rect.width * 0.2237,
           cornerHeight: rect.height * 0.2237,
           transform: nil)
}

// MARK: - Drawing

func drawIcon(size: CGFloat, into ctx: CGContext) {
    let scale = size / 1024.0
    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)

    let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)
    // 10% margin on each side is the standard macOS proportion.
    let plate = canvas.insetBy(dx: 100, dy: 100)
    let shape = squirclePath(in: plate)

    // Drop shadow, skipped at small sizes where it only muddies the edges.
    if size >= 128 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -14),
                      blur: 34,
                      color: NSColor.black.withAlphaComponent(0.30).cgColor)
        ctx.addPath(shape)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Plate: cool blue gradient, top-left light to bottom-right deep.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space,
                              colors: [
                                CGColor(colorSpace: space, components: [0.42, 0.79, 1.00, 1])!,
                                CGColor(colorSpace: space, components: [0.16, 0.47, 0.94, 1])!,
                                CGColor(colorSpace: space, components: [0.09, 0.25, 0.72, 1])!,
                              ] as CFArray,
                              locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: plate.minX, y: plate.maxY),
                           end: CGPoint(x: plate.maxX, y: plate.minY),
                           options: [])

    // Soft top highlight so the plate doesn't read flat.
    let highlight = CGGradient(colorsSpace: space,
                               colors: [
                                 CGColor(colorSpace: space, components: [1, 1, 1, 0.22])!,
                                 CGColor(colorSpace: space, components: [1, 1, 1, 0.0])!,
                               ] as CFArray,
                               locations: [0, 1])!
    ctx.drawRadialGradient(highlight,
                           startCenter: CGPoint(x: plate.midX, y: plate.maxY - 40),
                           startRadius: 0,
                           endCenter: CGPoint(x: plate.midX, y: plate.maxY - 40),
                           endRadius: plate.width * 0.75,
                           options: [])
    ctx.restoreGState()

    // Rotor.
    let center = CGPoint(x: plate.midX, y: plate.midY)
    let outerRadius = plate.width * 0.355
    let hubRadius = plate.width * 0.062
    let blades = 4

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6),
                  blur: 18,
                  color: NSColor.black.withAlphaComponent(0.22).cgColor)
    for i in 0..<blades {
        let base = (CGFloat(i) / CGFloat(blades)) * 2 * .pi
        // Root starts inside the hub so the joint is covered by it.
        let path = bladePath(center: center,
                             hubRadius: hubRadius * 0.72,
                             outerRadius: outerRadius,
                             baseAngle: base,
                             sweep: 44 * .pi / 180,
                             maxWidth: 40 * .pi / 180)
        ctx.addPath(path)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.97).cgColor)
        ctx.fillPath()
    }
    ctx.restoreGState()

    // Hub, with a punched-out centre so it reads as a rotor at 16px.
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(x: center.x - hubRadius, y: center.y - hubRadius,
                               width: hubRadius * 2, height: hubRadius * 2))
    ctx.setFillColor(CGColor(colorSpace: space, components: [0.13, 0.38, 0.87, 1])!)
    let inner = hubRadius * 0.42
    ctx.fillEllipse(in: CGRect(x: center.x - inner, y: center.y - inner,
                               width: inner * 2, height: inner * 2))

    ctx.restoreGState()
}

func renderPNG(size: Int, to url: URL) throws {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw Failure("could not create a \(size)px bitmap context")
    }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    drawIcon(size: CGFloat(size), into: ctx)

    guard let image = ctx.makeImage() else { throw Failure("could not snapshot the context") }
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw Failure("could not open \(url.path) for writing")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw Failure("could not write \(url.path)") }
}

struct Failure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Main

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
                 ? CommandLine.arguments[1]
                 : "Resources/AppIcon.icns")

// name -> pixel size, per the .iconset layout iconutil expects.
let variants: [(String, Int)] = [
    ("icon_16x16", 16),      ("icon_16x16@2x", 32),
    ("icon_32x32", 32),      ("icon_32x32@2x", 64),
    ("icon_128x128", 128),   ("icon_128x128@2x", 256),
    ("icon_256x256", 256),   ("icon_256x256@2x", 512),
    ("icon_512x512", 512),   ("icon_512x512@2x", 1024),
]

do {
    let iconset = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("M5Blade-\(getpid()).iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: iconset) }

    for (name, size) in variants {
        try renderPNG(size: size, to: iconset.appendingPathComponent("\(name).png"))
    }

    try FileManager.default.createDirectory(
        at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
    try task.run()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        throw Failure("iconutil failed with status \(task.terminationStatus)")
    }

    let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size]) as? Int ?? 0
    print("wrote \(output.path) (\(bytes) bytes)")

    // Keep a PNG next to the icns for the README and for eyeballing changes.
    let preview = output.deletingPathExtension().appendingPathExtension("png")
    try renderPNG(size: 512, to: preview)
    print("wrote \(preview.path)")
} catch {
    FileHandle.standardError.write(Data("make-icon: \(error.localizedDescription)\n".utf8))
    exit(1)
}

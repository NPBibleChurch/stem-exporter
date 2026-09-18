#!/usr/bin/env swift
// Draws the app icon and writes Resources/AppIcon.icns.
//   swift Scripts/make-icon.swift

import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
try? FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/StemExporter/Resources"), withIntermediateDirectories: true)

/// Stem heights, left to right: a handful of tracks at different levels.
let bars: [CGFloat] = [0.34, 0.62, 0.90, 0.48, 0.72, 0.30, 0.56, 0.84, 0.44]
/// The one drawn in the trim colour, so the icon says "these bits, not those".
let accentBar = 2

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    ctx.setShouldAntialias(true)

    // macOS icons sit inset inside their canvas.
    let inset = size * 0.09
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    ctx.saveGState()
    squircle.addClip()
    let gradient = NSGradient(
        colors: [
            NSColor(srgbRed: 0.09, green: 0.55, blue: 1.00, alpha: 1),
            NSColor(srgbRed: 0.03, green: 0.32, blue: 0.82, alpha: 1),
        ]
    )
    gradient?.draw(in: rect, angle: -90)

    let barWidth = rect.width / CGFloat(bars.count) * 0.42
    let spacing = rect.width / CGFloat(bars.count)
    let centreY = rect.midY

    for (index, height) in bars.enumerated() {
        let x = rect.minX + spacing * (CGFloat(index) + 0.5) - barWidth / 2
        let h = rect.height * 0.62 * height
        let bar = NSBezierPath(
            roundedRect: CGRect(x: x, y: centreY - h / 2, width: barWidth, height: h),
            xRadius: barWidth / 2,
            yRadius: barWidth / 2
        )
        if index == accentBar {
            NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1).setFill()
        } else {
            NSColor(white: 1, alpha: 0.95).setFill()
        }
        bar.fill()
    }
    ctx.restoreGState()

    return image
}

func png(_ image: NSImage, _ pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
    guard let data = png(drawIcon(size: CGFloat(pixels)), pixels) else { continue }
    try data.write(to: iconset.appendingPathComponent(name))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Sources/StemExporter/Resources/AppIcon.icns").path]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote Sources/StemExporter/Resources/AppIcon.icns" : "iconutil failed (\(task.terminationStatus))")

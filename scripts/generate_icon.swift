// Generates the app icon (AppIcon.icns) without Xcode.
// Draws a macOS-style rounded-square icon — night-sky control tower with
// radar rings and an airplane — renders every required size, and runs
// iconutil to produce assets/AppIcon.icns.
//
// Usage: swift scripts/generate_icon.swift

import AppKit

let canvas: CGFloat = 1024

func drawIcon(into context: CGContext) {
    let scale = canvas / 1024

    // macOS icon grid: 824pt rounded square centered in a 1024 canvas.
    let squareSize: CGFloat = 824 * scale
    let origin = (canvas - squareSize) / 2
    let square = CGRect(x: origin, y: origin, width: squareSize, height: squareSize)
    let path = CGPath(
        roundedRect: square, cornerWidth: 185 * scale, cornerHeight: 185 * scale, transform: nil)

    // Background: deep night-sky gradient.
    context.saveGState()
    context.addPath(path)
    context.clip()
    let colors = [
        CGColor(red: 0.04, green: 0.10, blue: 0.24, alpha: 1),
        CGColor(red: 0.13, green: 0.25, blue: 0.48, alpha: 1),
    ]
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray,
        locations: [0, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: canvas / 2, y: square.minY),
        end: CGPoint(x: canvas / 2, y: square.maxY),
        options: [])

    // Radar rings around the lower-left, like a control tower's sweep.
    let center = CGPoint(x: square.minX + squareSize * 0.30, y: square.minY + squareSize * 0.28)
    context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.22))
    for (index, radius) in [0.18, 0.34, 0.50, 0.66].enumerated() {
        context.setLineWidth((14 - CGFloat(index) * 2) * scale)
        context.strokeEllipse(in: CGRect(
            x: center.x - squareSize * radius, y: center.y - squareSize * radius,
            width: squareSize * radius * 2, height: squareSize * radius * 2))
    }
    // Radar center dot.
    context.setFillColor(CGColor(red: 1, green: 0.62, blue: 0.26, alpha: 1))
    let dotRadius = 26 * scale
    context.fillEllipse(in: CGRect(
        x: center.x - dotRadius, y: center.y - dotRadius,
        width: dotRadius * 2, height: dotRadius * 2))
    context.restoreGState()

    // Airplane: SF Symbol rendered white, climbing toward the upper right.
    let symbolSize = squareSize * 0.42
    let config = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .medium)
    guard let symbol = NSImage(systemSymbolName: "airplane", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) else { return }

    let tinted = NSImage(size: symbol.size)
    tinted.lockFocus()
    NSColor.white.set()
    let bounds = NSRect(origin: .zero, size: symbol.size)
    symbol.draw(in: bounds)
    bounds.fill(using: .sourceAtop)
    tinted.unlockFocus()

    let planeCenter = CGPoint(
        x: square.minX + squareSize * 0.56, y: square.minY + squareSize * 0.56)
    context.saveGState()
    context.translateBy(x: planeCenter.x, y: planeCenter.y)
    context.rotate(by: .pi / 7)  // climb angle
    if let cgImage = tinted.cgImage(forProposedRect: nil, context: nil, hints: nil) {
        let drawSize = CGSize(
            width: tinted.size.width * scale * 1.6, height: tinted.size.height * scale * 1.6)
        context.setShadow(
            offset: CGSize(width: 0, height: -8 * scale), blur: 24 * scale,
            color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.35))
        context.draw(cgImage, in: CGRect(
            x: -drawSize.width / 2, y: -drawSize.height / 2,
            width: drawSize.width, height: drawSize.height))
    }
    context.restoreGState()
}

func renderPNG(size: Int, to url: URL) {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.scaleBy(x: CGFloat(size) / canvas, y: CGFloat(size) / canvas)
    drawIcon(into: cg)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}

// Build the .iconset and convert with iconutil.
let fileManager = FileManager.default
let assetsDir = URL(fileURLWithPath: "assets")
let iconset = assetsDir.appendingPathComponent("AppIcon.iconset")
try? fileManager.removeItem(at: iconset)
try! fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for entry in sizes {
    renderPNG(size: entry.pixels, to: iconset.appendingPathComponent("\(entry.name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", assetsDir.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
try? fileManager.removeItem(at: iconset)
print(iconutil.terminationStatus == 0 ? "Generated assets/AppIcon.icns" : "iconutil failed")

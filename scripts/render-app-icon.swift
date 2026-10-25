import AppKit
import Foundation

// Repository-native vector source, rendered separately at each icon size.
// No external renderer, font, network access or AI-generated bitmap is involved.
let arguments = Array(CommandLine.arguments.dropFirst())
guard let outputPath = arguments.first else {
    fatalError("Usage: swift scripts/render-app-icon.swift OUTPUT_DIRECTORY [--install] [--previous ICNS]")
}
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let output = URL(fileURLWithPath: outputPath)
let svg = try String(contentsOf: root.appendingPathComponent("Resources/Brand/AppIcon.svg"), encoding: .utf8)
guard let artwork = NSImage(data: Data(svg.utf8)), artwork.isValid else { fatalError("Invalid SVG artwork") }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let iconset = output.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func png(size: Int, draw: (NSRect) -> Void) throws -> Data {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else { fatalError("Cannot create bitmap") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    draw(NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Cannot encode PNG") }
    return data
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let suffix = scale == 2 ? "@2x" : ""
        let data = try png(size: pixels) { rect in artwork.draw(in: rect) }
        try data.write(to: iconset.appendingPathComponent("icon_\(points)x\(points)\(suffix).png"))
    }
}
try png(size: 1024) { artwork.draw(in: $0) }.write(to: output.appendingPathComponent("AppIcon.png"))

// Keep the status-item silhouette in sync, without the plate or color.
guard let start = svg.range(of: "  <g id=\"mark\""),
      let end = svg.range(of: "  </g>", options: .backwards, range: start.upperBound..<svg.endIndex) else { fatalError("Missing mark") }
let mark = String(svg[start.lowerBound..<end.upperBound]).replacingOccurrences(of: "#70D333", with: "#000000")
    .replacingOccurrences(of: "#ffffff", with: "#000000")
    .replacingOccurrences(of: "#FFFFFF", with: "#000000")
let template = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"74\" height=\"74\" viewBox=\"11 11 74 74\">" + mark + "</svg>"
guard let templateImage = NSImage(data: Data(template.utf8)) else { fatalError("Invalid template") }
var mediaBox = CGRect(x: 0, y: 0, width: 74, height: 74)
guard let pdf = CGContext(output.appendingPathComponent("MenuBarIcon.pdf") as CFURL, mediaBox: &mediaBox, nil) else {
    fatalError("Cannot create template PDF")
}
pdf.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
templateImage.draw(in: mediaBox)
NSGraphicsContext.restoreGraphicsState()
pdf.endPDFPage()
pdf.closePDF()

let converter = Process()
converter.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
converter.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try converter.run()
converter.waitUntilExit()
guard converter.terminationStatus == 0 else { fatalError("iconutil failed") }

// Actual-size comparison on both appearances, not enlarged thumbnail claims.
let previous: NSImage? = arguments.firstIndex(of: "--previous").flatMap { index in
    guard arguments.indices.contains(index + 1) else { return nil }
    return NSImage(contentsOfFile: arguments[index + 1])
}
guard let previewArtwork = NSImage(contentsOf: output.appendingPathComponent("AppIcon.icns")) else {
    fatalError("Cannot read rendered icon")
}
let comparison = try png(size: 1024) { _ in
    for (row, background) in [NSColor(white: 0.95, alpha: 1), NSColor(white: 0.10, alpha: 1)].enumerated() {
        let y = CGFloat(1 - row) * 512
        background.setFill()
        NSRect(x: 0, y: y, width: 1024, height: 512).fill()
        for (column, image) in [previous ?? previewArtwork, previewArtwork].enumerated() {
            let x = CGFloat(column) * 512
            for (index, size) in [256, 128, 64, 32, 16].enumerated() {
                let position = [CGPoint(x: 32, y: 210), CGPoint(x: 326, y: 300), CGPoint(x: 326, y: 200),
                                CGPoint(x: 342, y: 126), CGPoint(x: 350, y: 72)][index]
                image.draw(in: NSRect(x: x + position.x, y: y + position.y, width: CGFloat(size), height: CGFloat(size)))
            }
        }
    }
}
try comparison.write(to: output.appendingPathComponent("comparison.png"))

if arguments.contains("--install") {
    let icon = try Data(contentsOf: output.appendingPathComponent("AppIcon.icns"))
    try icon.write(to: root.appendingPathComponent("Resources/AppIcon.icns"), options: .atomic)
    try icon.write(to: root.appendingPathComponent("Sources/MacSCPAppKit/Resources/AppIcon.icns"), options: .atomic)
    let menu = try Data(contentsOf: output.appendingPathComponent("MenuBarIcon.pdf"))
    try menu.write(to: root.appendingPathComponent("Sources/MacSCPAppKit/Resources/MenuBarIcon.pdf"), options: .atomic)
}
print("Rendered icon, template and size comparison in \(output.path)")

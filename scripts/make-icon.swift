// Renders the app icon into Resources/Assets.xcassets/AppIcon.appiconset.
// Usage: swift scripts/make-icon.swift [output-dir]
import AppKit

let output = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "Resources/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: 1024, height: 1024)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.setShouldAntialias(true)
    cg.interpolationQuality = .high

    // Body: macOS icon grid, 824pt squircle centred on a 1024pt canvas.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: NSColor.black.withAlphaComponent(0.32).cgColor)
    color(0x2B2F77).setFill()
    bodyPath.fill()
    cg.restoreGState()

    NSGradient(colors: [color(0x4F7CFF), color(0x6A4DF5), color(0x8B3FD9)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: bodyPath, angle: -65)

    // Soft light from the top edge.
    cg.saveGState()
    bodyPath.addClip()
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    cg.restoreGState()

    func window(_ rect: CGRect, titleTint: NSColor) {
        let radius: CGFloat = 34
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        cg.saveGState()
        cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        NSColor.white.withAlphaComponent(0.96).setFill()
        path.fill()
        cg.restoreGState()

        cg.saveGState()
        path.addClip()
        let bar = CGRect(x: rect.minX, y: rect.maxY - 58, width: rect.width, height: 58)
        titleTint.withAlphaComponent(0.16).setFill()
        bar.fill()
        let lights: [NSColor] = [color(0xFF5F57), color(0xFEBC2E), color(0x28C840)]
        for (index, light) in lights.enumerated() {
            light.setFill()
            NSBezierPath(ovalIn: CGRect(x: rect.minX + 30 + CGFloat(index) * 30, y: rect.maxY - 38, width: 19, height: 19)).fill()
        }
        // Content lines.
        color(0x6A4DF5, 0.18).setFill()
        var y = rect.maxY - 100
        var widthFactor: CGFloat = 0.72
        while y > rect.minY + 34 {
            NSBezierPath(roundedRect: CGRect(x: rect.minX + 32, y: y, width: (rect.width - 64) * widthFactor, height: 18),
                         xRadius: 9, yRadius: 9).fill()
            y -= 40
            widthFactor = widthFactor > 0.6 ? 0.48 : 0.8
        }
        cg.restoreGState()
    }

    window(CGRect(x: 176, y: 214, width: 380, height: 560), titleTint: color(0x4F7CFF))
    window(CGRect(x: 590, y: 480, width: 258, height: 294), titleTint: color(0x8B3FD9))
    window(CGRect(x: 590, y: 214, width: 258, height: 232), titleTint: color(0x6A4DF5))

    // Pin badge: the windows stay where they are.
    let badge = CGRect(x: 690, y: 668, width: 196, height: 196)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    let badgePath = NSBezierPath(ovalIn: badge)
    NSGradient(colors: [color(0xFFB340), color(0xFF7A1A)])!.draw(in: badgePath, angle: -90)
    cg.restoreGState()
    NSColor.white.withAlphaComponent(0.9).setStroke()
    badgePath.lineWidth = 8
    badgePath.stroke()
    let config = NSImage.SymbolConfiguration(pointSize: 104, weight: .bold)
    if let pin = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: pin.size, flipped: false) { rect in
            pin.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let size = tinted.size
        tinted.draw(in: CGRect(x: badge.midX - size.width / 2, y: badge.midY - size.height / 2, width: size.width, height: size.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let entries: [(name: String, pixels: Int, size: String, scale: String)] = [
    ("icon_16x16.png", 16, "16x16", "1x"), ("icon_16x16@2x.png", 32, "16x16", "2x"),
    ("icon_32x32.png", 32, "32x32", "1x"), ("icon_32x32@2x.png", 64, "32x32", "2x"),
    ("icon_128x128.png", 128, "128x128", "1x"), ("icon_128x128@2x.png", 256, "128x128", "2x"),
    ("icon_256x256.png", 256, "256x256", "1x"), ("icon_256x256@2x.png", 512, "256x256", "2x"),
    ("icon_512x512.png", 512, "512x512", "1x"), ("icon_512x512@2x.png", 1024, "512x512", "2x"),
]

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for entry in entries {
    try drawIcon(pixels: entry.pixels).write(to: output.appendingPathComponent(entry.name))
}
let images = entries.map { "    { \"filename\" : \"\($0.name)\", \"idiom\" : \"mac\", \"scale\" : \"\($0.scale)\", \"size\" : \"\($0.size)\" }" }
let contents = "{\n  \"images\" : [\n\(images.joined(separator: ",\n"))\n  ],\n  \"info\" : { \"author\" : \"xcode\", \"version\" : 1 }\n}\n"
try contents.write(to: output.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(entries.count) icon sizes to \(output.path)")

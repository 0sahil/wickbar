// Generates Wickbar's app icon: a white flame on a warm, rounded-square gradient.
// Usage: make-icon <output.iconset directory>
import AppKit

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write("usage: make-icon <output.iconset>\n".data(using: .utf8)!)
    exit(2)
}
let outDir = URL(fileURLWithPath: args[1])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    let s = CGFloat(pixels)

    // macOS icon grid: the rounded square occupies ~80% of the canvas.
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Soft drop shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowBlurRadius = s * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01)
    shadow.set()
    NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.15, alpha: 1).setFill()
    squircle.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Warm gradient: amber at the top to deep red-orange at the bottom.
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 1.00, green: 0.78, blue: 0.30, alpha: 1),
        NSColor(calibratedRed: 0.98, green: 0.50, blue: 0.16, alpha: 1),
        NSColor(calibratedRed: 0.86, green: 0.22, blue: 0.12, alpha: 1),
    ], atLocations: [0, 0.55, 1], colorSpace: .deviceRGB)!
    gradient.draw(in: squircle, angle: -90)

    // Subtle top highlight.
    NSGraphicsContext.saveGraphicsState()
    squircle.addClip()
    let highlight = NSGradient(starting: NSColor.white.withAlphaComponent(0.22), ending: NSColor.white.withAlphaComponent(0))!
    highlight.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)
    NSGraphicsContext.restoreGraphicsState()

    // Flame glyph (SF Symbol), tinted white.
    let pointSize = rect.height * 0.58
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "flame.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let tinted = NSImage(size: symbol.size, flipped: false) { r in
            symbol.draw(in: r)
            NSColor.white.set()
            r.fill(using: .sourceAtop)
            return true
        }
        let size = tinted.size
        let scale = min(rect.width * 0.62 / size.width, rect.height * 0.62 / size.height)
        let w = size.width * scale, h = size.height * scale
        let target = NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2 - rect.height * 0.01, width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        let glow = NSShadow()
        glow.shadowColor = NSColor(calibratedRed: 0.6, green: 0.1, blue: 0.0, alpha: 0.45)
        glow.shadowBlurRadius = s * 0.02
        glow.shadowOffset = NSSize(width: 0, height: -s * 0.006)
        glow.set()
        tinted.draw(in: target)
        NSGraphicsContext.restoreGraphicsState()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in sizes {
    try render(pixels: px).write(to: outDir.appendingPathComponent(name))
}
print("Wrote \(sizes.count) icon images to \(outDir.path)")

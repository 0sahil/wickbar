// Draws the DMG window background ("drag Wickbar to Applications").
// Usage: swiftc -O -o make-dmg-background scripts/make-dmg-background.swift && ./make-dmg-background <out-dir>
// Writes background.png (660x400) and background@2x.png (1320x800); combine with
//   tiffutil -cathidpicheck background.png background@2x.png -out background.tiff
// Icon centres in the DMG window are at (165, 185) and (495, 185) (top-left origin), 128pt icons.
import AppKit

let width: CGFloat = 660
let height: CGFloat = 400

func render(scale: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    // Warm, light background so Finder's black icon labels stay readable.
    let bg = NSGradient(colors: [
        NSColor(calibratedRed: 1.00, green: 0.985, blue: 0.96, alpha: 1),
        NSColor(calibratedRed: 1.00, green: 0.94, blue: 0.87, alpha: 1),
    ])!
    bg.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    // Three chevrons between the two icon slots (icons centred at y = 185 from the top),
    // fading in left to right so they read as motion towards Applications.
    let cy = height - 185
    let arrowColor = NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.15, alpha: 1)
    for (i, x) in [292.0, 330.0, 368.0].enumerated() {
        let chevron = NSBezierPath()
        chevron.move(to: NSPoint(x: x, y: cy + 20))
        chevron.line(to: NSPoint(x: x + 20, y: cy))
        chevron.line(to: NSPoint(x: x, y: cy - 20))
        chevron.lineWidth = 8
        chevron.lineCapStyle = .round
        chevron.lineJoinStyle = .round
        arrowColor.withAlphaComponent(0.4 + 0.3 * CGFloat(i)).setStroke()
        chevron.stroke()
    }

    // Caption.
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let title = NSAttributedString(string: "Drag Wickbar to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 19, weight: .semibold),
        .foregroundColor: NSColor(calibratedWhite: 0.16, alpha: 1),
        .paragraphStyle: para,
    ])
    title.draw(in: NSRect(x: 0, y: 70, width: width, height: 28))
    let sub = NSAttributedString(string: "Then open it from Applications — it lives in your menu bar.", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: NSColor(calibratedWhite: 0.38, alpha: 1),
        .paragraphStyle: para,
    ])
    sub.draw(in: NSRect(x: 0, y: 46, width: width, height: 20))

    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
try render(scale: 1).write(to: URL(fileURLWithPath: outDir).appendingPathComponent("background.png"))
try render(scale: 2).write(to: URL(fileURLWithPath: outDir).appendingPathComponent("background@2x.png"))
print("wrote \(outDir)/background.png and background@2x.png")

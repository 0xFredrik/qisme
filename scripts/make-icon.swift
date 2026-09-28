import AppKit

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = NSAffineTransform()
        transform.scale(by: CGFloat(pixels) / 512)
        transform.concat()
        NSColor(calibratedRed: 0.08, green: 0.14, blue: 0.23, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 26, y: 26, width: 460, height: 460), xRadius: 100, yRadius: 100).fill()
        NSColor(calibratedRed: 0.35, green: 0.88, blue: 0.72, alpha: 1).setStroke()
        let screen = NSBezierPath(roundedRect: NSRect(x: 86, y: 175, width: 340, height: 220), xRadius: 20, yRadius: 20)
        screen.lineWidth = 18
        screen.stroke()
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: 256, y: 175)); stand.line(to: NSPoint(x: 256, y: 120))
        stand.move(to: NSPoint(x: 192, y: 120)); stand.line(to: NSPoint(x: 320, y: 120))
        stand.lineWidth = 18; stand.lineCapStyle = .round; stand.stroke()
        let text = "⇄" as NSString
        let style: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 88, weight: .bold), .foregroundColor: NSColor.white]
        let bounds = text.size(withAttributes: style)
        text.draw(at: NSPoint(x: (512 - bounds.width) / 2, y: 235), withAttributes: style)
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}

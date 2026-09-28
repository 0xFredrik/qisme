import AppKit

// Finder places the actual app and Applications icons over this background.
let width = 600, height = 360
let output = URL(fileURLWithPath: CommandLine.arguments[1])
for scale in [1, 2] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * scale,
        pixelsHigh: height * scale, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    func centered(_ text: String, y: CGFloat, size: CGFloat, weight: NSFont.Weight, shade: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: NSColor(calibratedWhite: shade, alpha: 1)
        ]
        let text = text as NSString
        let bounds = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: (CGFloat(width) - bounds.width) / 2, y: y), withAttributes: attributes)
    }
    centered("Input Selector", y: 290, size: 25, weight: .semibold, shade: 0.12)
    centered("Drag Input Selector to Applications", y: 48, size: 15, weight: .regular, shade: 0.35)

    NSColor(calibratedWhite: 0.55, alpha: 1).setStroke()
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: 267, y: 180))
    arrow.line(to: NSPoint(x: 333, y: 180))
    arrow.move(to: NSPoint(x: 320, y: 193))
    arrow.line(to: NSPoint(x: 333, y: 180))
    arrow.line(to: NSPoint(x: 320, y: 167))
    arrow.lineWidth = 3
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(
        to: scale == 1 ? output : output.deletingLastPathComponent()
            .appendingPathComponent(output.deletingPathExtension().lastPathComponent + "@2x.png"))
}

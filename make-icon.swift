import AppKit

let taskDirectory = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = taskDirectory.appendingPathComponent("build/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
func drawIcon(size: Int, filename: String) throws {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                              isPlanar: false, colorSpaceName: .deviceRGB,
                              bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    let outer = NSBezierPath(roundedRect: NSRect(x: 65, y: 65, width: 894, height: 894), xRadius: 205, yRadius: 205)
    NSGradient(starting: NSColor(srgbRed: 0.08, green: 0.64, blue: 0.48, alpha: 1), ending: NSColor(srgbRed: 0.04, green: 0.32, blue: 0.32, alpha: 1))!.draw(in: outer, angle: -65)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: NSRect(x: 230, y: 240, width: 564, height: 540), xRadius: 60, yRadius: 60).fill()
    NSColor(srgbRed: 0.75, green: 0.91, blue: 0.86, alpha: 1).setFill()
    NSBezierPath(rect: NSRect(x: 230, y: 630, width: 564, height: 45)).fill()
    NSColor.white.setStroke()
    for x: CGFloat in [350, 674] {
        let ring = NSBezierPath()
        ring.lineWidth = 44
        ring.lineCapStyle = .round
        ring.move(to: NSPoint(x: x, y: 747))
        ring.line(to: NSPoint(x: x, y: 828))
        ring.stroke()
    }
    NSColor(srgbRed: 0.05, green: 0.48, blue: 0.37, alpha: 1).setStroke()
    let check = NSBezierPath()
    check.lineWidth = 52
    check.lineCapStyle = .round
    check.lineJoinStyle = .round
    check.move(to: NSPoint(x: 370, y: 454))
    check.line(to: NSPoint(x: 470, y: 354))
    check.line(to: NSPoint(x: 668, y: 552))
    check.stroke()
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(filename))
}
for size in [16, 32, 128, 256, 512] {
    try drawIcon(size: size, filename: "icon_\(size)x\(size).png")
    try drawIcon(size: size * 2, filename: "icon_\(size)x\(size)@2x.png")
}

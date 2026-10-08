// Draws the app icon into an .iconset folder (run by scripts/bundle.sh): a dark tile, three devices cabled in a triangle
// in the protocol colours, an ICMP packet on the bottom cable.
import AppKit

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

/// One square PNG, `px` pixels wide, drawn on a 1024-point grid.
func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    // macOS icon grid: an 824-point tile with 185-point corners, centred.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s), xRadius: 185 * s, yRadius: 185 * s)
    color(0x2B2D30).setFill()
    tile.fill()
    color(0x393B40).setStroke()
    tile.lineWidth = 8 * s
    tile.stroke()
    let nodes = [NSPoint(x: 512 * s, y: 700 * s), NSPoint(x: 300 * s, y: 330 * s), NSPoint(x: 724 * s, y: 330 * s)]
    let cable = NSBezierPath()
    cable.move(to: nodes[0])
    cable.line(to: nodes[1])
    cable.line(to: nodes[2])
    cable.close()
    color(0x6F737A).setStroke()
    cable.lineWidth = 22 * s
    cable.stroke()
    for (p, hex) in zip(nodes, [UInt32(0x3574F0), 0x5FB865, 0xB083F0]) {
        color(hex).setFill()
        NSBezierPath(roundedRect: NSRect(x: p.x - 95 * s, y: p.y - 70 * s, width: 190 * s, height: 140 * s), xRadius: 28 * s, yRadius: 28 * s).fill()
    }
    color(0xE5507A).setFill()
    NSBezierPath(ovalIn: NSRect(x: 468 * s, y: 286 * s, width: 88 * s, height: 88 * s)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try draw(size).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size).png"))
    try draw(size * 2).write(to: URL(fileURLWithPath: "\(out)/icon_\(size)x\(size)@2x.png"))
}

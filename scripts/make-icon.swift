// Renders Daymark's app icon to an .icns file: swift scripts/make-icon.swift <out.icns>
import AppKit

let out = CommandLine.arguments[1]
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("Daymark.iconset")
try? FileManager.default.removeItem(at: tmp)
try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = body.width * 0.225
    let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)
    NSColor.white.setFill(); shape.fill()
    shape.addClip()
    let band = NSRect(x: body.minX, y: body.maxY - body.height * 0.26, width: body.width, height: body.height * 0.26)
    NSColor(red: 0.10, green: 0.45, blue: 0.91, alpha: 1).setFill(); NSBezierPath(rect: band).fill()
    let p = NSMutableParagraphStyle(); p.alignment = .center
    let num = NSAttributedString(string: "31", attributes: [
        .font: NSFont.systemFont(ofSize: body.height * 0.46, weight: .semibold),
        .foregroundColor: NSColor(white: 0.20, alpha: 1), .paragraphStyle: p])
    let nh = num.size().height
    num.draw(in: NSRect(x: body.minX, y: body.minY + (body.height * 0.74 - nh) / 2, width: body.width, height: nh))
    let dot = body.width * 0.11
    NSColor(red: 0.92, green: 0.26, blue: 0.21, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: body.maxX - dot * 2.1, y: body.minY + dot * 1.1, width: dot, height: dot)).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try! render(size).write(to: tmp.appendingPathComponent("icon_\(size)x\(size).png"))
    try! render(size * 2).write(to: tmp.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", tmp.path, "-o", out]
try! p.run(); p.waitUntilExit()
exit(p.terminationStatus)

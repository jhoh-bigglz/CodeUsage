// Renders the app icon "</*>" (Codex blue brackets/slash + Claude terracotta asterisk) and builds
// Resources/AppIcon.icns. Usage: swift scripts/make-icon.swift  (run from the repo root)
import AppKit
import Foundation

let blue = NSColor(srgbRed: 0x5B / 255.0, green: 0x8D / 255.0, blue: 0xEF / 255.0, alpha: 1)
let blueLight = NSColor(srgbRed: 0x8A / 255.0, green: 0xB0 / 255.0, blue: 0xFF / 255.0, alpha: 1)
let terracotta = NSColor(srgbRed: 0xD9 / 255.0, green: 0x77 / 255.0, blue: 0x57 / 255.0, alpha: 1)
let terracottaLight = NSColor(srgbRed: 0xF0 / 255.0, green: 0x9A / 255.0, blue: 0x7A / 255.0, alpha: 1)

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: s, height: s)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // macOS icon grid: 824 pt body inset 100 pt, continuous-ish corners.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

    // Drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1).setFill()
    squircle.fill()
    ctx.restoreGState()

    // Background gradient.
    ctx.saveGState()
    squircle.addClip()
    NSGradient(colors: [
        NSColor(srgbRed: 0x2E / 255.0, green: 0x2F / 255.0, blue: 0x36 / 255.0, alpha: 1),
        NSColor(srgbRed: 0x15 / 255.0, green: 0x15 / 255.0, blue: 0x19 / 255.0, alpha: 1),
    ])!.draw(in: body, angle: -90)
    // Soft top highlight.
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.07), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
    ctx.restoreGState()

    // Hairline border.
    NSColor.white.withAlphaComponent(0.08).setStroke()
    let border = NSBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: 185, yRadius: 185)
    border.lineWidth = 3
    border.stroke()

    func strokePath(_ points: [CGPoint], width: CGFloat, colors: [NSColor]) {
        let path = CGMutablePath()
        path.addLines(between: points)
        ctx.saveGState()
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.addPath(path)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let bounds = path.boundingBox.insetBy(dx: -width, dy: -width)
        NSGradient(colors: colors)!.draw(in: bounds, angle: -90)
        ctx.restoreGState()
    }

    let w: CGFloat = 54
    // "<"
    strokePath([CGPoint(x: 302, y: 642), CGPoint(x: 222, y: 512), CGPoint(x: 302, y: 382)], width: w, colors: [blueLight, blue])
    // "/"
    strokePath([CGPoint(x: 392, y: 382), CGPoint(x: 472, y: 642)], width: w, colors: [blueLight, blue])
    // ">"
    strokePath([CGPoint(x: 722, y: 642), CGPoint(x: 802, y: 512), CGPoint(x: 722, y: 382)], width: w, colors: [blueLight, blue])
    // "*" — six rounded rays.
    let center = CGPoint(x: 598, y: 512)
    let radius: CGFloat = 84
    for k in 0..<3 {
        let angle = CGFloat.pi / 2 + CGFloat(k) * .pi / 3
        let dx = cos(angle) * radius, dy = sin(angle) * radius
        strokePath([CGPoint(x: center.x - dx, y: center.y - dy), CGPoint(x: center.x + dx, y: center.y + dy)],
                   width: 46, colors: [terracottaLight, terracotta])
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon-\(getpid()).iconset")
try? fm.removeItem(at: iconset)
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let resources = root.appendingPathComponent("Resources")
try fm.createDirectory(at: resources, withIntermediateDirectories: true)
try render(size: 1024).write(to: resources.appendingPathComponent("AppIcon.png"))

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try task.run()
task.waitUntilExit()
try? fm.removeItem(at: iconset)
guard task.terminationStatus == 0 else { fatalError("iconutil failed") }
print("wrote Resources/AppIcon.icns and Resources/AppIcon.png")

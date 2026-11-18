// Composes README screenshots from `--render-preview` output (built-in sample data, no real account data).
// Usage (from the repo root):
//   build/CodeUsage.app/Contents/MacOS/CodeUsage --render-preview /tmp/cu-shots \
//       -claudeShowsRemaining NO -codexShowsRemaining YES   # app defaults, without touching saved settings
//   swift scripts/make-readme-shots.swift /tmp/cu-shots docs/images
// Writes hero-light.png / hero-dark.png: a menu bar strip with the status item and the popover below it.
import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write("usage: make-readme-shots.swift <preview-dir> <out-dir>\n".data(using: .utf8)!)
    exit(2)
}
let previewDir = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

func load(_ name: String) -> NSBitmapImageRep {
    let url = previewDir.appendingPathComponent(name)
    guard let data = try? Data(contentsOf: url), let rep = NSBitmapImageRep(data: data) else {
        fatalError("cannot read \(url.path)")
    }
    return rep
}

func compose(dark: Bool) throws {
    let popover = load(dark ? "popover-dark.png" : "popover-light.png")
    let menubar = load(dark ? "menubar-dark.png" : "menubar-light.png")
    let barColor = menubar.colorAt(x: 1, y: 1) ?? (dark ? .black : .white)

    // All sizes in pixels (previews are rendered at 2x).
    let popW = CGFloat(popover.pixelsWide), popH = CGFloat(popover.pixelsHigh)
    let mbW = CGFloat(menubar.pixelsWide), mbH = CGFloat(menubar.pixelsHigh)
    let width: CGFloat = popW + 200
    let stripH: CGFloat = mbH + 8
    let gap: CGFloat = 26
    let bottom: CGFloat = 90
    let height = stripH + gap + popH + bottom

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // Flip to top-left origin for easier layout.
    ctx.translateBy(x: 0, y: height)
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)

    // Wallpaper-like background.
    let canvas = CGRect(x: 0, y: 0, width: width, height: height)
    let bg = dark
        ? [NSColor(srgbRed: 0.16, green: 0.13, blue: 0.27, alpha: 1), NSColor(srgbRed: 0.07, green: 0.09, blue: 0.17, alpha: 1)]
        : [NSColor(srgbRed: 0.80, green: 0.66, blue: 0.86, alpha: 1), NSColor(srgbRed: 0.62, green: 0.74, blue: 0.95, alpha: 1)]
    NSGradient(colors: bg)!.draw(in: canvas, angle: 90)

    // Menu bar strip.
    barColor.withAlphaComponent(0.92).setFill()
    CGRect(x: 0, y: 0, width: width, height: stripH).fill()

    // Status item, with a highlight capsule like an open menu.
    let mbX = width / 2 + 60 - mbW / 2
    let mbY = (stripH - mbH) / 2
    let highlight = NSBezierPath(roundedRect: CGRect(x: mbX - 10, y: mbY, width: mbW + 20, height: mbH),
                                 xRadius: 12, yRadius: 12)
    (dark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.09)).setFill()
    highlight.fill()
    // The label PNG is opaque: "multiply" keeps dark text on light, "screen" keeps light text on dark,
    // so only the glyphs show over the highlight.
    menubar.draw(in: CGRect(x: mbX, y: mbY, width: mbW, height: mbH), from: .zero,
                 operation: dark ? .screen : .multiply, fraction: 1, respectFlipped: true, hints: nil)

    // Popover, centred under the status item, rounded with a soft shadow and hairline border.
    var popX = mbX + mbW / 2 - popW / 2
    popX = min(max(popX, 40), width - popW - 40)
    let popRect = CGRect(x: popX, y: stripH + gap, width: popW, height: popH)
    let shape = NSBezierPath(roundedRect: popRect, xRadius: 36, yRadius: 36)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 50,
                  color: NSColor.black.withAlphaComponent(dark ? 0.55 : 0.28).cgColor)
    (popover.colorAt(x: 4, y: 4) ?? .white).setFill()
    shape.fill()
    ctx.restoreGState()
    ctx.saveGState()
    shape.addClip()
    popover.draw(in: popRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    ctx.restoreGState()
    (dark ? NSColor.white.withAlphaComponent(0.14) : NSColor.black.withAlphaComponent(0.12)).setStroke()
    shape.lineWidth = 2
    shape.stroke()

    NSGraphicsContext.restoreGraphicsState()
    let out = outDir.appendingPathComponent(dark ? "hero-dark.png" : "hero-light.png")
    try rep.representation(using: .png, properties: [:])!.write(to: out)
    print("wrote \(out.path)")
}

try compose(dark: false)
try compose(dark: true)

// Generates Resources/AppIcon.icns. Run: swift scripts/make-icon.swift .
// A squircle with a slate-to-indigo gradient and a white remote drawn from plain shapes
// (no SF Symbols: their license doesn't allow use in app icons).
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    // macOS icon grid: 824/1024 body with ~185/1024 corner radius, centered.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.12, blue: 0.20, alpha: 1),
                        NSColor(srgbRed: 0.27, green: 0.33, blue: 0.62, alpha: 1)])!.draw(in: squircle, angle: 70)

    // The remote: a tall white rounded slab, with the clickpad and buttons cut in the
    // background's dark tone.
    let u = s / 1024
    let remote = NSRect(x: s / 2 - 150 * u, y: 170 * u, width: 300 * u, height: 684 * u)
    NSColor.white.setFill()
    NSBezierPath(roundedRect: remote, xRadius: 150 * u, yRadius: 150 * u).fill()
    let ink = NSColor(srgbRed: 0.16, green: 0.19, blue: 0.34, alpha: 1)
    ink.setFill()
    let cx = remote.midX
    let pad: CGFloat = 220 * u
    NSBezierPath(ovalIn: NSRect(x: cx - pad / 2, y: remote.maxY - 60 * u - pad, width: pad, height: pad)).fill()
    NSColor.white.setFill()
    let inner: CGFloat = 70 * u
    NSBezierPath(ovalIn: NSRect(x: cx - inner / 2, y: remote.maxY - 60 * u - pad / 2 - inner / 2, width: inner, height: inner)).fill()
    ink.setFill()
    let b: CGFloat = 76 * u, gap: CGFloat = 30 * u
    let rowY = remote.maxY - 60 * u - pad - 50 * u - b
    for dx in [-(b + gap) / 2, (b + gap) / 2] {
        NSBezierPath(ovalIn: NSRect(x: cx + dx - b / 2, y: rowY, width: b, height: b)).fill()
        NSBezierPath(ovalIn: NSRect(x: cx + dx - b / 2, y: rowY - b - gap, width: b, height: b)).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let set = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (pt, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for sc in scales {
        let name = sc == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
        try! render(pt * sc).write(to: set.appendingPathComponent(name))
    }
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print("wrote Resources/AppIcon.icns")

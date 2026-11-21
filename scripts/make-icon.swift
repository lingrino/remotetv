// Generates Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
// A squircle with a slate-to-indigo gradient and a white Siri Remote silhouette (SF Symbol appletvremote.gen4.fill).
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
    let path = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGradient(colors: [NSColor(srgbRed: 0.10, green: 0.12, blue: 0.20, alpha: 1),
                        NSColor(srgbRed: 0.27, green: 0.33, blue: 0.62, alpha: 1)])!.draw(in: path, angle: 70)
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.56, weight: .regular)
        .applying(.init(paletteColors: [.white]))
    let sym = NSImage(systemSymbolName: "appletvremote.gen4.fill", accessibilityDescription: nil)!.withSymbolConfiguration(cfg)!
    let sz = sym.size
    sym.draw(in: NSRect(x: body.midX - sz.width / 2, y: body.midY - sz.height / 2, width: sz.width, height: sz.height))
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

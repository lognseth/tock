// Renders Resources/AppIcon.icns. Run: swift Scripts/make-icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    // Squircle plate with the standard macOS icon inset.
    let inset = s * 0.098
    let plate = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = CGPath(roundedRect: plate, cornerWidth: plate.width * 0.225, cornerHeight: plate.width * 0.225, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let colors = [NSColor(red: 0.36, green: 0.45, blue: 1.0, alpha: 1).cgColor,
                  NSColor(red: 0.42, green: 0.22, blue: 0.86, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: plate.minX, y: plate.maxY), end: CGPoint(x: plate.maxX, y: plate.minY), options: [])
    // Soft top highlight.
    let hi = [NSColor.white.withAlphaComponent(0.18).cgColor, NSColor.white.withAlphaComponent(0).cgColor] as CFArray
    let hg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: hi, locations: [0, 1])!
    ctx.drawLinearGradient(hg, start: CGPoint(x: s / 2, y: plate.maxY), end: CGPoint(x: s / 2, y: s * 0.45), options: [])
    ctx.restoreGState()

    // Ring and check.
    let c = CGPoint(x: s / 2, y: s / 2)
    let r = plate.width * 0.30
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setLineWidth(plate.width * 0.055)
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.02, color: NSColor.black.withAlphaComponent(0.25).cgColor)
    ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.setLineWidth(plate.width * 0.075)
    ctx.move(to: CGPoint(x: c.x - r * 0.42, y: c.y - r * 0.02))
    ctx.addLine(to: CGPoint(x: c.x - r * 0.08, y: c.y - r * 0.40))
    ctx.addLine(to: CGPoint(x: c.x + r * 0.46, y: c.y + r * 0.34))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = "build/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: dir)
try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", dir, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try? FileManager.default.removeItem(atPath: dir)
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")

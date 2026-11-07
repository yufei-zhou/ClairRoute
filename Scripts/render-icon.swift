import AppKit
import CoreGraphics

// Usage: swift Scripts/render-icon.swift <project root>
// Draws the app icon (an open white ring and the node past its gap, on a blue gradient)
// at every native size, then packs Resources/AppIcon.icns. No GUI or network is used.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = root.appendingPathComponent(".build/icon/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let space = CGColorSpace(name: CGColorSpace.displayP3)!
func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [CGFloat((hex >> 16) & 255) / 255, CGFloat((hex >> 8) & 255) / 255,
                                            CGFloat(hex & 255) / 255, alpha])!
}
/// macOS icon grid: an 824 pt body centred in 1024 with continuous (superellipse) corners.
func squircle() -> CGPath {
    let path = CGMutablePath()
    for step in 0...720 {
        let t = Double(step) / 720 * 2 * .pi
        let x = 512 + 412 * copysign(pow(abs(cos(t)), 0.4), cos(t))
        let y = 512 + 412 * copysign(pow(abs(sin(t)), 0.4), sin(t))
        step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
    }
    path.closeSubpath(); return path
}
/// White glyph with a soft drop shadow and a faint vertical tint.
func fillGlyph(_ context: CGContext, _ shape: CGPath) {
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: color(0x0A2A66, 0.28))
    context.addPath(shape); context.setFillColor(color(0xFFFFFF)); context.fillPath()
    context.restoreGState()
    context.saveGState(); context.addPath(shape); context.clip()
    let tint = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF), color(0xDCE9FF)] as CFArray, locations: [0.35, 1])!
    let box = shape.boundingBox
    context.drawLinearGradient(tint, start: CGPoint(x: box.midX, y: box.minY), end: CGPoint(x: box.midX, y: box.maxY), options: [])
    context.restoreGState()
}
func render(_ pixels: Int) -> Data {
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.translateBy(x: 0, y: 1024); context.scaleBy(x: 1, y: -1) // y grows downwards
    let tile = squircle()
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: color(0x000000, 0.28))
    context.addPath(tile); context.setFillColor(color(0x1F6BEB)); context.fillPath()
    context.restoreGState()
    context.saveGState(); context.addPath(tile); context.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x5CB8FF), color(0x1F6BEB)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(background, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    let sheen = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(sheen, startCenter: CGPoint(x: 512, y: 120), startRadius: 0,
                               endCenter: CGPoint(x: 512, y: 120), endRadius: 620, options: [])
    let ring = CGMutablePath()
    ring.addArc(center: CGPoint(x: 490, y: 540), radius: 210, startAngle: -.pi * 0.28, endAngle: .pi * 0.28, clockwise: true)
    fillGlyph(context, ring.copy(strokingWithWidth: 110, lineCap: .round, lineJoin: .round, miterLimit: 10))
    fillGlyph(context, CGPath(ellipseIn: CGRect(x: 676, y: 262, width: 120, height: 120), transform: nil))
    context.restoreGState()
    context.addPath(tile); context.setStrokeColor(color(0xFFFFFF, 0.14)); context.setLineWidth(3); context.strokePath()
    return NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        try render(size * scale).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"))
    }
}
try render(1024).write(to: root.appendingPathComponent("Resources/AppIcon.png"))
let pack = Process()
pack.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
pack.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try pack.run(); pack.waitUntilExit()
guard pack.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote Resources/AppIcon.icns and Resources/AppIcon.png")

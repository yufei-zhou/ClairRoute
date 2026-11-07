import AppKit
import CoreGraphics

// Vector master matches Resources/AppIcon.svg. Rasterize each native size directly,
// rather than repeatedly downscaling a bitmap. No GUI or network is used.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = root.appendingPathComponent(".build/icon/AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 255) / 255,
            green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func render(_ pixels: Int) throws -> Data {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: pixels * 4, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.translateBy(x: 0, y: 1024); context.scaleBy(x: 1, y: -1)
    let tile = CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
                      cornerWidth: 208, cornerHeight: 208, transform: nil)
    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: 8), blur: 16, color: rgb(0x08182B, alpha: 0.22))
    context.addPath(tile); context.setFillColor(rgb(0x142A43)); context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(tile); context.clip()
    let gradient = CGGradient(colorsSpace: colorSpace, colors: [rgb(0x245E84), rgb(0x142A43)] as CFArray,
                              locations: [0, 1])!
    context.drawLinearGradient(gradient, start: CGPoint(x: 160, y: 64), end: CGPoint(x: 864, y: 960), options: [])
    context.restoreGState()
    context.addPath(CGPath(roundedRect: CGRect(x: 65, y: 65, width: 894, height: 894),
                           cornerWidth: 207, cornerHeight: 207, transform: nil))
    context.setStrokeColor(rgb(0xFFFFFF, alpha: 0.18)); context.setLineWidth(2); context.strokePath()
    let route = CGMutablePath()
    route.move(to: CGPoint(x: 340, y: 706)); route.addLine(to: CGPoint(x: 340, y: 508))
    route.addCurve(to: CGPoint(x: 460, y: 388), control1: CGPoint(x: 340, y: 438), control2: CGPoint(x: 390, y: 388))
    route.addLine(to: CGPoint(x: 574, y: 388))
    route.addCurve(to: CGPoint(x: 684, y: 278), control1: CGPoint(x: 644, y: 388), control2: CGPoint(x: 684, y: 348))
    context.addPath(route); context.setStrokeColor(rgb(0xF1F7FA)); context.setLineWidth(84)
    context.setLineCap(.round); context.setLineJoin(.round); context.strokePath()
    context.setFillColor(rgb(0x99DFDE)); context.fillEllipse(in: CGRect(x: 639, y: 233, width: 90, height: 90))
    let image = NSBitmapImageRep(cgImage: context.makeImage()!)
    return image.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try render(size * scale).write(to: iconset.appendingPathComponent(name))
    }
}
try render(1024).write(to: root.appendingPathComponent("Resources/AppIcon.png"))
print(iconset.path)

// Renders the app icon. Run from the repo root: swift scripts/make-icon.swift
// Writes Resources/AppIcon.icns and docs/icon.png.
import AppKit

let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r, g, b, a])!
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
}

func context(_ side: Int) -> CGContext {
    CGContext(
        data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func drawIcon() -> CGImage {
    let ctx = context(1024)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: color(0, 0, 0, 0.35))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0.08, 0.08, 0.14))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([color(0.20, 0.21, 0.42), color(0.06, 0.06, 0.13)]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: []
    )

    // The display, with the island hanging from its top edge.
    let screen = CGRect(x: 100, y: 250, width: 824, height: 674)
    ctx.clip(to: screen)
    ctx.drawLinearGradient(
        gradient([color(0.42, 0.40, 0.86), color(0.20, 0.36, 0.72), color(0.10, 0.14, 0.32)]),
        start: CGPoint(x: 260, y: screen.maxY), end: CGPoint(x: 760, y: screen.minY), options: []
    )
    ctx.drawLinearGradient(
        gradient([color(1, 1, 1, 0.14), color(1, 1, 1, 0)]),
        start: CGPoint(x: 512, y: screen.maxY), end: CGPoint(x: 512, y: 640), options: []
    )
    ctx.restoreGState()

    let top: CGFloat = 924
    let island = CGRect(x: 512 - 250, y: top - 210, width: 500, height: 210)
    let r: CGFloat = 92
    let ear: CGFloat = 22
    let path = CGMutablePath()
    path.move(to: CGPoint(x: island.minX - ear, y: top))
    path.addQuadCurve(to: CGPoint(x: island.minX, y: top - ear), control: CGPoint(x: island.minX, y: top))
    path.addLine(to: CGPoint(x: island.minX, y: island.minY + r))
    path.addQuadCurve(to: CGPoint(x: island.minX + r, y: island.minY), control: CGPoint(x: island.minX, y: island.minY))
    path.addLine(to: CGPoint(x: island.maxX - r, y: island.minY))
    path.addQuadCurve(to: CGPoint(x: island.maxX, y: island.minY + r), control: CGPoint(x: island.maxX, y: island.minY))
    path.addLine(to: CGPoint(x: island.maxX, y: top - ear))
    path.addQuadCurve(to: CGPoint(x: island.maxX + ear, y: top), control: CGPoint(x: island.maxX, y: top))
    path.closeSubpath()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0, 0, 0, 0.55))
    ctx.addPath(path)
    ctx.setFillColor(color(0, 0, 0))
    ctx.fillPath()
    ctx.restoreGState()

    // A finished session: green check and two lines of text.
    let badge = CGRect(x: island.minX + 52, y: island.minY + 52, width: 104, height: 104)
    ctx.setFillColor(color(0.32, 0.82, 0.48, 0.22))
    ctx.fillEllipse(in: badge)
    ctx.setStrokeColor(color(0.36, 0.88, 0.52))
    ctx.setLineWidth(15)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: badge.minX + 30, y: badge.midY + 2))
    ctx.addLine(to: CGPoint(x: badge.minX + 47, y: badge.midY - 16))
    ctx.addLine(to: CGPoint(x: badge.maxX - 26, y: badge.midY + 20))
    ctx.strokePath()

    func line(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ alpha: CGFloat) {
        let rect = CGRect(x: x, y: y, width: width, height: height)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: height / 2, cornerHeight: height / 2, transform: nil))
        ctx.setFillColor(color(1, 1, 1, alpha))
        ctx.fillPath()
    }
    line(badge.maxX + 34, badge.midY + 10, 196, 30, 0.95)
    line(badge.maxX + 34, badge.midY - 36, 140, 24, 0.45)

    // Trackpad hint at the bottom, for the haptic click.
    let pad = CGRect(x: 512 - 150, y: 150, width: 300, height: 62)
    ctx.addPath(CGPath(roundedRect: pad, cornerWidth: 24, cornerHeight: 24, transform: nil))
    ctx.setFillColor(color(1, 1, 1, 0.08))
    ctx.fillPath()

    return ctx.makeImage()!
}

func scaled(_ image: CGImage, to side: Int) -> CGImage {
    let ctx = context(side)
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    try data.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let icon = drawIcon()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try writePNG(scaled(icon, to: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try writePNG(scaled(icon, to: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()

try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
try writePNG(scaled(icon, to: 256), to: root.appendingPathComponent("docs/icon.png"))
print(iconutil.terminationStatus == 0 ? "wrote Resources/AppIcon.icns and docs/icon.png" : "iconutil failed")

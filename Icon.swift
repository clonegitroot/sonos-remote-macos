// SPDX-License-Identifier: GPL-3.0-only
import AppKit

let target = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
let variants = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64),
                ("128x128", 128), ("128x128@2x", 256), ("256x256", 256),
                ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

for (name, size) in variants {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    let scale = CGFloat(size) / 1024
    NSGraphicsContext.current!.cgContext.scaleBy(x: scale, y: scale)

    let tile = NSBezierPath(roundedRect: NSRect(x: 88, y: 88, width: 848, height: 848), xRadius: 205, yRadius: 205)
    let gradient = NSGradient(starting: color(0.24, 0.28, 0.34), ending: color(0.08, 0.10, 0.14))!
    gradient.draw(in: tile, angle: -60)
    color(1, 1, 1, 0.16).setStroke()
    tile.lineWidth = 4
    tile.stroke()

    func cabinet(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, front: Bool) {
        let body = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: 68, yRadius: 68)
        NSGradient(starting: front ? color(0.96, 1, 0.93) : color(0.51, 0.61, 0.65),
                   ending: front ? color(0.65, 0.85, 0.74) : color(0.29, 0.37, 0.43))!.draw(in: body, angle: -90)
        let cx = x + width / 2
        for (offset, radius) in [(height * 0.32, width * 0.29), (height * 0.73, width * 0.14)] {
            let cy = y + offset
            color(0.09, 0.13, 0.15).setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2)).fill()
            let center = radius * 0.45
            color(0.27, 0.36, 0.37).setFill()
            NSBezierPath(ovalIn: NSRect(x: cx - center, y: cy - center, width: center * 2, height: center * 2)).fill()
        }
    }
    cabinet(529, 326, 225, 386, front: false)
    cabinet(280, 247, 313, 530, front: true)
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: target.appendingPathComponent("icon_\(name).png"))
}

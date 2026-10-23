import AppKit
import CoreGraphics

let side = 1024
let S = CGFloat(side)
let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError() }
ctx.interpolationQuality = .high

// ── 圆角方块（macOS 图标形状）
let radius = S * 0.2237
let squircle = CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                      cornerWidth: radius, cornerHeight: radius, transform: nil)
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()

// ── 底色：深靛蓝 → 墨蓝，斜向渐变
let g = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.255, green: 0.318, blue: 0.640, alpha: 1),
    CGColor(red: 0.055, green: 0.067, blue: 0.121, alpha: 1)
] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])

// ── 左上柔光，制造玻璃质感
let glow = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.13),
    CGColor(red: 1, green: 1, blue: 1, alpha: 0.0)
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow,
                       startCenter: CGPoint(x: S * 0.26, y: S * 0.80), startRadius: 0,
                       endCenter: CGPoint(x: S * 0.26, y: S * 0.80), endRadius: S * 0.62, options: [])

// ── 顶部高光细线（玻璃边缘）
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
ctx.fill(CGRect(x: 0, y: S - 2.5, width: S, height: 2.5))

// ── 蓝牙符文（标准 24 格路径）
let pts: [(CGFloat, CGFloat)] = [
    (6.5, 6.5), (17.5, 17.5), (12.0, 23.0), (12.0, 1.0), (17.5, 6.5), (6.5, 17.5)
]
let scale = S * 0.60 / 24.0
let offX = (S - 24 * scale) / 2
let offY = (S - 24 * scale) / 2
let path = CGMutablePath()
for (i, p) in pts.enumerated() {
    let x = offX + p.0 * scale
    let y = offY + (24 - p.1) * scale      // 翻 y
    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
}
ctx.setLineWidth(S * 0.058)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
// 轻微外发光
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.006), blur: S * 0.03,
              color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.25))
ctx.addPath(path)
ctx.strokePath()
ctx.restoreGState()
ctx.addPath(path)
ctx.strokePath()

ctx.restoreGState()

guard let img = ctx.makeImage() else { fatalError() }
let rep = NSBitmapImageRep(cgImage: img)
try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("ok")

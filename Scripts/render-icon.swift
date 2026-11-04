// 生成 Moting 的 app 图标与菜单栏图标（CoreGraphics 绘制，透明背景）。
// 用法：swift Scripts/render-icon.swift App/Moting/Assets.xcassets
// 设计（2026-11-04）：石墨色底上的"一来一回"——亮白（我）说完，灰（对方）接上，两段旋转对称。
// 和 app 底部的双声部声纹带是同一个图形；logo 保持单色，彩色留给 app 内部
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets.xcassets")
let space = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint, locations: [CGFloat]? = nil) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

/// 连续曲率圆角方形（超椭圆近似 macOS 图标外形）
func squircle(_ r: CGRect, n: CGFloat = 4.2) -> CGPath {
    let p = CGMutablePath()
    for i in 0...720 {
        let t = CGFloat(i) / 720 * 2 * .pi
        let c = cos(t), s = sin(t)
        let pt = CGPoint(x: r.midX + r.width / 2 * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n),
                         y: r.midY + r.height / 2 * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n))
        i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

/// 上半（我）每根柱子的高度，下半（对方）是它的倒序，所以整体旋转对称
/// 大图标 7 根；小尺寸细节会糊，用 5 根
let barsLarge: [CGFloat] = [11, 23, 33, 15, 0, 0, 0]
let barsSmall: [CGFloat] = [14, 31, 14, 0, 0]

/// 画声纹标记：柱子从中轴向两侧长，圆头。width/gap/高度都按 unit 缩放
func drawMark(_ ctx: CGContext, center: CGPoint, unit u: CGFloat, bars: [CGFloat], width: CGFloat, gap: CGFloat,
              axisGap: CGFloat, top: CGColor, bottom: CGColor) {
    let total = CGFloat(bars.count) * width + CGFloat(bars.count - 1) * gap
    for (i, h) in bars.enumerated() {
        let x = center.x + (-total / 2 + CGFloat(i) * (width + gap)) * u
        if h > 0 {
            let up = CGRect(x: x, y: center.y + axisGap / 2 * u, width: width * u, height: h * u)
            ctx.addPath(CGPath(roundedRect: up, cornerWidth: width / 2 * u, cornerHeight: width / 2 * u, transform: nil))
            ctx.setFillColor(top)
            ctx.fillPath()
        }
        let d = bars[bars.count - 1 - i]
        if d > 0 {
            let down = CGRect(x: x, y: center.y - axisGap / 2 * u - d * u, width: width * u, height: d * u)
            ctx.addPath(CGPath(roundedRect: down, cornerWidth: width / 2 * u, cornerHeight: width / 2 * u, transform: nil))
            ctx.setFillColor(bottom)
            ctx.fillPath()
        }
    }
}

func drawIcon(size: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // 苹果模板：1024 画布中 824×824 的图标，四周留 100
    let o = size * 100 / 1024, w = size * 824 / 1024, u = w / 100
    let tile = CGRect(x: o, y: o, width: w, height: w)
    let tilePath = squircle(tile)

    // 外投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x121215))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    linear(ctx, [color(0x232326), color(0x0B0B0C)], from: CGPoint(x: 0, y: tile.maxY), to: CGPoint(x: 0, y: tile.minY))
    let center = CGPoint(x: tile.midX, y: tile.midY)
    let cyan = color(0xEDEDEF), amber = color(0x8E8E93)
    if size <= 64 {
        drawMark(ctx, center: center, unit: u, bars: barsSmall, width: 11, gap: 4.5, axisGap: 3, top: cyan, bottom: amber)
    } else {
        drawMark(ctx, center: center, unit: u, bars: barsLarge, width: 8, gap: 3.2, axisGap: 2.4, top: cyan, bottom: amber)
    }
    ctx.restoreGState()

    // 外沿一圈极细的亮边，深色桌面上也分得清轮廓
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.setLineWidth(max(1, size * 0.004))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    linear(ctx, [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0.05)], from: CGPoint(x: 0, y: tile.maxY), to: CGPoint(x: 0, y: tile.minY))
    ctx.restoreGState()
    return ctx.makeImage()!
}

/// 菜单栏图标：18pt 单色，同 app 图标的 5 根版本。hex 为黑色时由系统按明暗着色；录音中画红色
func drawMenuIcon(scale: CGFloat, hex: UInt32) -> CGImage {
    let px = 18 * scale
    let ctx = CGContext(data: nil, width: Int(px), height: Int(px), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let c = color(hex)
    drawMark(ctx, center: CGPoint(x: px / 2, y: px / 2), unit: scale, bars: [3.4, 7.4, 3.4, 0, 0], width: 2.4,
             gap: 0.9, axisGap: 0.8, top: c, bottom: c)
    return ctx.makeImage()!
}

func writePNG(_ img: CGImage, _ url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: img)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
}

func writeJSON(_ obj: Any, _ url: URL) throws {
    try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]).write(to: url)
}

let fm = FileManager.default
let iconSet = out.appendingPathComponent("AppIcon.appiconset")
try? fm.removeItem(at: iconSet)
try fm.createDirectory(at: iconSet, withIntermediateDirectories: true)
var images: [[String: String]] = []
for pt in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
        try writePNG(drawIcon(size: CGFloat(pt * scale)), iconSet.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(pt)x\(pt)", "scale": "\(scale)x", "filename": name])
    }
}
try writeJSON(["images": images, "info": ["author": "xcode", "version": 1]], iconSet.appendingPathComponent("Contents.json"))

for (name, hex, template) in [("MenuBarIcon", UInt32(0x000000), true), ("MenuBarIconRecording", UInt32(0xFF383C), false)] {
    let set = out.appendingPathComponent("\(name).imageset")
    try? fm.removeItem(at: set)
    try fm.createDirectory(at: set, withIntermediateDirectories: true)
    var imgs: [[String: String]] = []
    for scale in [1, 2] {
        let file = "\(name)\(scale == 2 ? "@2x" : "").png"
        try writePNG(drawMenuIcon(scale: CGFloat(scale), hex: hex), set.appendingPathComponent(file))
        imgs.append(["idiom": "universal", "scale": "\(scale)x", "filename": file])
    }
    var json: [String: Any] = ["images": imgs, "info": ["author": "xcode", "version": 1]]
    if template { json["properties"] = ["template-rendering-intent": "template"] }
    try writeJSON(json, set.appendingPathComponent("Contents.json"))
}
try writeJSON(["info": ["author": "xcode", "version": 1]], out.appendingPathComponent("Contents.json"))
print("已生成：\(out.path)")

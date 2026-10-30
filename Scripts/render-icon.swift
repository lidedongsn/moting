// 生成 Moting 的 app 图标与菜单栏图标（CoreGraphics 绘制，透明背景）。
// 用法：swift Scripts/render-icon.swift App/Moting/Assets.xcassets
// 设计：A 造型（声波 → 文字行）+ C 配色（石墨黑底），颜色取 macOS 26 深色系统色，带玻璃高光
import AppKit
import CoreGraphics

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets.xcassets")

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let cyan: UInt32 = 0x3CD3FE     // macOS 26 深色 cyan（"我"）
let yellow: UInt32 = 0xFFD600   // macOS 26 深色 yellow（"对方"）

/// 设计稿坐标 0–100（y 向下），映射到苹果模板：1024 画布中 824×824 的圆角方形，四周留 100
struct Canvas {
    let ctx: CGContext
    let size: CGFloat
    var s: CGFloat { size * 824 / 1024 / 100 }
    var o: CGFloat { size * 100 / 1024 }
    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: o + x * s, y: size - (o + (y + h) * s), width: w * s, height: h * s)
    }
}

func linear(_ ctx: CGContext, _ colors: [CGColor], from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func drawIcon(size: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let c = Canvas(ctx: ctx, size: size)
    let tile = c.rect(0, 0, 100, 100)
    let radius = 22.5 * c.s
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 外投影（苹果模板的轻微落影）
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.010), blur: size * 0.022, color: color(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x1A1A1D))
    ctx.fillPath()
    ctx.restoreGState()

    // 石墨渐变底
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    linear(ctx, [color(0x34343A), color(0x16161A), color(0x0E0E10)], from: CGPoint(x: 0, y: tile.maxY), to: CGPoint(x: 0, y: tile.minY))
    // 顶部玻璃高光
    linear(ctx, [color(0xFFFFFF, 0.14), color(0xFFFFFF, 0)], from: CGPoint(x: 0, y: tile.maxY), to: CGPoint(x: 0, y: tile.midY + tile.height * 0.05))

    // 声波柱：蓝黄交替，上亮下暗的光泽 + 柔和投影
    let bars: [(CGFloat, CGFloat, CGFloat, UInt32)] = [
        (15, 40, 20, cyan), (23.5, 29, 42, yellow), (32, 20, 60, cyan), (40.5, 33, 34, yellow), (49, 42.5, 15, cyan),
    ]
    for (x, y, h, hex) in bars {
        let r = c.rect(x, y, 5.5, h)
        let p = CGPath(roundedRect: r, cornerWidth: r.width / 2, cornerHeight: r.width / 2, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.006), blur: size * 0.018, color: color(hex, 0.45))
        ctx.addPath(p)
        ctx.setFillColor(color(hex))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(p)
        ctx.clip()
        linear(ctx, [color(0xFFFFFF, 0.45), color(0xFFFFFF, 0.0), color(0x000000, 0.12)],
               from: CGPoint(x: 0, y: r.maxY), to: CGPoint(x: 0, y: r.minY))
        ctx.restoreGState()
    }

    // 文字行：磨砂白，逐行变淡
    for (y, w, a) in [(CGFloat(33), CGFloat(26), CGFloat(1)), (47.25, 20, 0.78), (61.5, 24, 0.56)] {
        let r = c.rect(60, y, w, 5.5)
        let p = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
        ctx.saveGState()
        ctx.addPath(p)
        ctx.clip()
        linear(ctx, [color(0xFFFFFF, a), color(0xE4E4EA, a)], from: CGPoint(x: 0, y: r.maxY), to: CGPoint(x: 0, y: r.minY))
        ctx.restoreGState()
    }
    ctx.restoreGState()

    // 内沿亮边（Liquid Glass 的边缘反光），上亮下暗
    ctx.saveGState()
    let rimWidth = max(1, size * 0.004)
    let inset = tile.insetBy(dx: rimWidth / 2, dy: rimWidth / 2)
    ctx.addPath(CGPath(roundedRect: inset, cornerWidth: radius - rimWidth / 2, cornerHeight: radius - rimWidth / 2, transform: nil))
    ctx.setLineWidth(rimWidth)
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    linear(ctx, [color(0xFFFFFF, 0.32), color(0xFFFFFF, 0.06), color(0xFFFFFF, 0.14)],
           from: CGPoint(x: 0, y: tile.maxY), to: CGPoint(x: 0, y: tile.minY))
    ctx.restoreGState()
    return ctx.makeImage()!
}

/// 菜单栏图标：18pt 单色。template 为 true 时画黑色（系统按明暗着色），否则画红色（录音中）
func drawMenuIcon(scale: CGFloat, hex: UInt32) -> CGImage {
    let px = 18 * scale
    let ctx = CGContext(data: nil, width: Int(px), height: Int(px), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(color(hex))
    let shapes: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (1, 7, 1.6, 4), (3.6, 5, 1.6, 8), (6.2, 3, 1.6, 12), (8.8, 6, 1.6, 6),
        (11.5, 5.5, 5.5, 1.6), (11.5, 8.2, 4.2, 1.6), (11.5, 10.9, 5, 1.6),
    ]
    for (x, y, w, h) in shapes {
        let r = CGRect(x: x * scale, y: px - (y + h) * scale, width: w * scale, height: h * scale)
        let rad = min(w, h) / 2 * scale
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil))
    }
    ctx.fillPath()
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

// 生成 Moting 的 app 图标与菜单栏图标（CoreGraphics 绘制，透明背景）。
// 用法：swift Scripts/render-icon.swift App/Moting/Assets.xcassets
// 设计（2026-11-02）："一笔"——一条线从声波（听）渐平成直线（转写），末端聚成 ✦（总结）。
// 青→紫渐变底：左上接 app 内的青色主色，右下的紫色呼应 AI 纪要；macOS 26 连续曲率外形 + 玻璃高光
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

func radial(_ ctx: CGContext, _ colors: [CGColor], center: CGPoint, radius: CGFloat) {
    let g = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [.drawsAfterEndLocation])
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

/// "一笔"的中心线，坐标 0–100（y 向上）：x 14–40 振荡且振幅衰减，40–53 为直线
func strokeCenterline(_ map: (CGFloat, CGFloat) -> CGPoint) -> CGPath {
    let p = CGMutablePath()
    let x0: CGFloat = 14, x1: CGFloat = 40, x2: CGFloat = 53
    for i in 0...500 {
        let x = x0 + (x2 - x0) * CGFloat(i) / 500
        let k = max(0, (x1 - x) / (x1 - x0))
        let y = 50 + 22 * pow(k, 1.1) * sin((x - x0) * 0.5)
        i == 0 ? p.move(to: map(x, y)) : p.addLine(to: map(x, y))
    }
    return p
}

/// 四角星 ✦
func sparkle(center c: CGPoint, big: CGFloat, small: CGFloat) -> CGPath {
    let p = CGMutablePath()
    for j in 0..<8 {
        let ang = CGFloat(j) * .pi / 4 + .pi / 2
        let r = j % 2 == 0 ? big : small
        let pt = CGPoint(x: c.x + r * cos(ang), y: c.y + r * sin(ang))
        j == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
}

/// 白色玻璃件：落影 + 本体 + 上部高光
func glass(_ ctx: CGContext, _ path: CGPath, size: CGFloat) {
    let box = path.boundingBox
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.035, color: color(0x1A0B4A, 0.35))
    ctx.addPath(path)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    linear(ctx, [color(0xFFFFFF), color(0xE9ECFF)], from: CGPoint(x: 0, y: box.maxY), to: CGPoint(x: 0, y: box.minY))
    ctx.restoreGState()
}

func drawIcon(size: CGFloat) -> CGImage {
    let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // 苹果模板：1024 画布中 824×824 的图标，四周留 100
    let o = size * 100 / 1024, w = size * 824 / 1024, u = w / 100
    let tile = CGRect(x: o, y: o, width: w, height: w)
    let tilePath = squircle(tile)
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o + x * u, y: o + y * u) }

    // 外投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.03, color: color(0x000000, 0.3))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0x4A7BE8))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()
    // 青→紫渐变底，左上一点亮
    linear(ctx, [color(0x2BB8F0), color(0x6D3FE0)], from: CGPoint(x: tile.minX, y: tile.maxY), to: CGPoint(x: tile.maxX, y: tile.minY))
    radial(ctx, [color(0xFFFFFF, 0.18), color(0xFFFFFF, 0)], center: pt(22, 86), radius: 70 * u)

    // 一笔：小尺寸加粗，免得线糊掉
    let width = (size <= 64 ? 8.5 : 6.2) * u
    let line = strokeCenterline(pt).copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
    glass(ctx, line, size: size)
    ctx.saveGState()
    ctx.addPath(line)
    ctx.clip()
    ctx.setBlendMode(.screen)
    linear(ctx, [color(0xFFFFFF, 0.5), color(0xFFFFFF, 0)], from: pt(0, 78), to: pt(0, 46))
    ctx.restoreGState()
    glass(ctx, sparkle(center: pt(73, 50), big: 18 * u, small: (size <= 64 ? 5.5 : 4.4) * u), size: size)
    ctx.restoreGState()

    // 外沿镜面亮边：左上亮、右下暗
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.setLineWidth(max(1, size * 0.005))
    ctx.replacePathWithStrokedPath()
    ctx.clip()
    linear(ctx, [color(0xFFFFFF, 0.55), color(0xFFFFFF, 0.08), color(0xFFFFFF, 0.25)],
           from: CGPoint(x: tile.minX, y: tile.maxY), to: CGPoint(x: tile.maxX, y: tile.minY), locations: [0, 0.6, 1])
    ctx.restoreGState()
    return ctx.makeImage()!
}

/// 菜单栏图标：18pt 单色，同 app 图标的"一笔"。template 为 true 时画黑色（系统按明暗着色），否则画红色（录音中）
func drawMenuIcon(scale: CGFloat, hex: UInt32) -> CGImage {
    let px = 18 * scale
    let ctx = CGContext(data: nil, width: Int(px), height: Int(px), bitsPerComponent: 8, bytesPerRow: 0,
                        space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(color(hex))
    // 中心线坐标 14–53 映射到 0.8–10.5pt，星在 14.3pt
    let k = 9.7 / 39 * scale
    let line = strokeCenterline { x, y in CGPoint(x: 0.8 * scale + (x - 14) * k, y: px / 2 + (y - 50) * k) }
        .copy(strokingWithWidth: 1.6 * scale, lineCap: .round, lineJoin: .round, miterLimit: 1)
    ctx.addPath(line)
    ctx.addPath(sparkle(center: CGPoint(x: 14.3 * scale, y: px / 2), big: 3.5 * scale, small: 1 * scale))
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

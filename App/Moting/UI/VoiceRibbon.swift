import SwiftUI

/// 双声道声纹带：上半"我"、下半对方（逐段按说话人着色），★ 标记、播放头；点击或拖动跳转。
/// 已播放部分全色，未播放部分淡化
struct VoiceRibbon: View {
    /// 0–1 包络，长度相同
    let mine: [Float]
    let theirs: [Float]
    /// 下半每一根柱子的颜色（与 theirs 等长）
    let theirColors: [Color]
    /// 0–1 位置
    let marks: [Double]
    let progress: Double
    let onSeek: (Double) -> Void

    private let laneHeight: CGFloat = 28

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    draw(ctx, size)
                }
                // ★ 标记
                ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                    Text("★")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.mark)
                        .position(x: width * m, y: 4)
                }
                // 播放头
                Capsule()
                    .fill(.primary)
                    .frame(width: 2, height: laneHeight * 2 + 10)
                    .overlay(alignment: .top) { Circle().fill(.primary).frame(width: 9, height: 9).offset(y: -3) }
                    .position(x: width * min(max(progress, 0), 1), y: 12 + laneHeight)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                onSeek(min(max(v.location.x / max(width, 1), 0), 1))
            })
        }
        .frame(height: laneHeight * 2 + 18)
        .accessibilityElement()
        .accessibilityLabel("声纹带播放进度")
        .accessibilityValue("\(Int(progress * 100))%")
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize) {
        let n = max(mine.count, theirs.count)
        guard n > 0 else { return }
        let gap: CGFloat = 2
        let barW = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
        let mid: CGFloat = 12 + laneHeight
        // 中轴线
        ctx.fill(Path(CGRect(x: 0, y: mid - 0.25, width: size.width, height: 0.5)), with: .color(.secondary.opacity(0.35)))
        for i in 0..<n {
            let x = CGFloat(i) * (barW + gap)
            let played = Double(i) / Double(n) <= progress
            let dim = played ? 1.0 : 0.42
            let m = i < mine.count ? CGFloat(mine[i]) : 0
            let t = i < theirs.count ? CGFloat(theirs[i]) : 0
            let up = max(1.5, m * (laneHeight - 2))
            let down = max(1.5, t * (laneHeight - 2))
            let meColor = m > 0.04 ? Theme.me.opacity(dim) : Color.secondary.opacity(0.25)
            let themColor = t > 0.04 ? (i < theirColors.count ? theirColors[i] : Theme.them).opacity(dim) : Color.secondary.opacity(0.25)
            ctx.fill(Path(roundedRect: CGRect(x: x, y: mid - 1 - up, width: barW, height: up), cornerRadius: barW / 2), with: .color(meColor))
            ctx.fill(Path(roundedRect: CGRect(x: x, y: mid + 1, width: barW, height: down), cornerRadius: barW / 2), with: .color(themColor))
        }
    }
}

/// 侧栏里的迷你声纹条：相邻同一说话人合并成连续色段，无人说话为浅灰
struct MiniTimeline: View {
    let colors: [Color?]

    private var runs: [(color: Color?, count: Int)] {
        var out: [(Color?, Int)] = []
        for c in colors {
            if let last = out.last, last.0 == c { out[out.count - 1].1 += 1 } else { out.append((c, 1)) }
        }
        return out
    }

    var body: some View {
        GeometryReader { g in
            HStack(spacing: 0) {
                ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                    Rectangle()
                        .fill(run.color ?? Color.secondary.opacity(0.15))
                        .frame(width: g.size.width * CGFloat(run.count) / CGFloat(max(colors.count, 1)))
                }
            }
        }
        .frame(height: 5)
        .clipShape(Capsule())
    }
}

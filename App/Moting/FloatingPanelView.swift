import MotingCore
import SwiftUI

/// 悬浮窗内容：顶部状态栏、中间字幕区、底部操作区；收起时只剩一条胶囊
struct FloatingPanelView: View {
    @ObservedObject var recorder: RecordingController
    @ObservedObject var ui: FloatingPanelState

    var body: some View {
        VStack(spacing: 0) {
            header
            if !ui.collapsed {
                Divider().overlay(Color.white.opacity(0.08))
                subtitles
                Divider().overlay(Color.white.opacity(0.08))
                actions
            }
        }
        .foregroundStyle(.white)
        .background(.ultraThinMaterial.opacity(0.6))
        .background(Color(white: 0.11).opacity(0.86))
        .clipShape(RoundedRectangle(cornerRadius: ui.collapsed ? 20 : 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ui.collapsed ? 20 : 12, style: .continuous)
            .strokeBorder(Color.white.opacity(0.12)))
        .environment(\.colorScheme, .dark)
        .contextMenu { opacityMenu }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(.tertiary)
            Circle()
                .fill(recorder.state == .paused ? Color.orange : Color.red)
                .frame(width: 8, height: 8)
                .shadow(color: recorder.state == .paused ? .orange : .red, radius: 3)
            Text(recorder.elapsed.clockText).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            MiniLevel(level: recorder.levels[.mic] ?? 0, color: Color(red: 0.39, green: 0.82, blue: 1))
            MiniLevel(level: recorder.levels[.system] ?? 0, color: Color(red: 1, green: 0.84, blue: 0.04))
            if ui.collapsed {
                Text(recorder.state == .paused ? "已暂停" : "录音中").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if ui.collapsed {
                iconButton("star.fill", help: "标记重点") { recorder.mark() }
                iconButton("stop.fill", help: "结束", tint: .red) { recorder.stop() }
            }
            iconButton(ui.collapsed ? "chevron.down" : "minus", help: ui.collapsed ? "展开" : "收起") {
                ui.collapsed.toggle()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
    }

    private var subtitles: some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            // P2 接入实时识别后，这里滚动显示最近 4–6 句，我 / 对方分色，未定稿片段为灰色
            Text("实时字幕将在接入语音识别后显示")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Label("我", systemImage: "circle.fill")
                    .foregroundStyle(Color(red: 0.39, green: 0.82, blue: 1))
                Label("对方", systemImage: "circle.fill")
                    .foregroundStyle(Color(red: 1, green: 0.84, blue: 0.04))
            }
            .font(.system(size: 10))
            .labelStyle(SmallDotLabelStyle())
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
    }

    private var actions: some View {
        HStack(spacing: 6) {
            pillButton("★ 标记重点") { recorder.mark() }
            if recorder.state == .paused {
                pillButton("▶ 继续") { recorder.resume() }
            } else {
                pillButton("⏸ 暂停") { recorder.pause() }
            }
            Spacer()
            pillButton(recorder.isStopping ? "正在结束…" : "■ 结束", tint: .red) { recorder.stop() }
                .disabled(recorder.isStopping)
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    @ViewBuilder
    private var opacityMenu: some View {
        Text("透明度")
        ForEach([1.0, 0.85, 0.7, 0.55], id: \.self) { v in
            Button("\(Int(v * 100))%\(abs(ui.opacity - v) < 0.01 ? " ✓" : "")") { ui.opacity = v }
        }
    }

    private func iconButton(_ name: String, help: String, tint: Color = .white,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint == .white ? Color.white.opacity(0.8) : tint)
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func pillButton(_ title: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(tint ?? Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}

private struct MiniLevel: View {
    let level: Float
    let color: Color

    var body: some View {
        // 4 根竖条，按电平点亮
        let lit = min(4, Int(((level * 50).squareRoot() / 3) * 4.99))
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < lit ? color : Color.white.opacity(0.15))
                    .frame(width: 3, height: CGFloat(5 + i * 2))
            }
        }
        .frame(height: 12)
    }
}

private struct SmallDotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.font(.system(size: 5))
            configuration.title
        }
    }
}

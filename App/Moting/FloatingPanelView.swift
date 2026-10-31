import MotingCore
import SwiftUI

/// 悬浮窗内容：顶部状态栏、中间字幕区、底部操作区；收起时只剩一条胶囊
struct FloatingPanelView: View {
    @ObservedObject var recorder: RecordingController
    @ObservedObject var live: LiveTranscriptModel
    @ObservedObject var processing: ProcessingModel
    @ObservedObject var ui: FloatingPanelState

    /// 录音已结束、正在显示会后处理状态
    private var showingProcessing: Bool {
        !(recorder.state == .recording || recorder.state == .paused || recorder.state == .stopping)
            && processing.lastRecordedMeetingID != nil
    }

    // macOS 26 深色系统色，与 app 图标一致
    // 悬浮窗固定为深色玻璃，直接用图标原色
    static let micColor = Color(hex: 0x3CD3FE)
    static let systemColor = Color(hex: 0xFFD600)

    var body: some View {
        VStack(spacing: 0) {
            if showingProcessing {
                processingView
            } else {
                recordingView
            }
        }
        .foregroundStyle(.white)
        // 玻璃：材质 + 深色底 + 上亮下暗的细描边（macOS 26 Liquid Glass 的近似）
        .background(.ultraThinMaterial)
        .background(Color(white: 0.1).opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: ui.collapsed ? 22 : 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: ui.collapsed ? 22 : 18, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom),
                          lineWidth: 0.7))
        .environment(\.colorScheme, .dark)
        .contextMenu { opacityMenu }
    }

    /// 录音结束后：会后精准转写的进度
    private var processingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                switch processing.lastStatus {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("精准转写完成").font(.system(size: 12, weight: .semibold))
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("精准转写失败，可在主窗口重试").font(.system(size: 12, weight: .semibold))
                case .waitingForPower:
                    Image(systemName: "powerplug").foregroundStyle(.secondary)
                    Text("接通电源后自动精准转写").font(.system(size: 12, weight: .semibold))
                case .paused:
                    Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
                    Text("精准转写已暂停").font(.system(size: 12, weight: .semibold))
                default:
                    ProgressView().controlSize(.small)
                    Text("正在精准转写… \(Int((processing.lastRecordedMeetingID.flatMap { processing.progress[$0] } ?? 0) * 100))%")
                        .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                }
                Spacer()
                iconButton("xmark", help: "关闭（转写在后台继续）") { processing.dismissLastRecorded() }
            }
            if !ui.collapsed, processing.lastStatus == .waitingForPower, let id = processing.lastRecordedMeetingID {
                pillButton("现在处理") { processing.processNow(id) }
            }
            if !ui.collapsed, let id = processing.lastRecordedMeetingID {
                switch processing.lastStatus {
                case .queued, .running: pillButton("暂停") { processing.pause(id) }
                case .paused: pillButton("继续") { processing.resume(id) }
                default: EmptyView()
                }
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var recordingView: some View {
        VStack(spacing: 0) {
            header
            if !ui.collapsed {
                Divider().overlay(Color.white.opacity(0.08))
                subtitles
                Divider().overlay(Color.white.opacity(0.08))
                actions
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").font(.caption).foregroundStyle(.tertiary)
            Circle()
                .fill(recorder.state == .paused ? Color.orange : Color.red)
                .frame(width: 8, height: 8)
                .shadow(color: recorder.state == .paused ? .orange : .red, radius: 3)
            Text(recorder.elapsed.clockText).font(.system(size: 12, weight: .semibold)).monospacedDigit()
            MiniLevel(level: recorder.levels[.mic] ?? 0, color: Self.micColor)
            MiniLevel(level: recorder.levels[.system] ?? 0, color: Self.systemColor)
            if ui.collapsed {
                Text(recorder.state == .paused ? "已暂停" : "录音中").font(.caption).foregroundStyle(.secondary)
            }
            if !recorder.warnings.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .help(recorder.warnings.joined(separator: "\n"))
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
        VStack(alignment: .leading, spacing: 4) {
            ForEach(recorder.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch live.modelState {
            case .ready:
                transcriptLines
            case .missing:
                modelPrompt("实时字幕需要先下载识别模型（约 \(ByteCountFormatter.string(fromByteCount: live.selectedModel.totalSize, countStyle: .file))）",
                            action: ("下载", { live.installSelected() }))
            case .downloading(let p):
                VStack(alignment: .leading, spacing: 4) {
                    Text("正在下载识别模型… \(Int(p * 100))%").font(.system(size: 11)).foregroundStyle(.secondary)
                    ProgressView(value: p).progressViewStyle(.linear).tint(.white.opacity(0.7))
                    Text("下载完成后，本场录音会自动开始显示字幕").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                .frame(maxHeight: .infinity)
            case .loading:
                modelPrompt("正在加载识别模型…", action: nil)
            case .failed(let msg):
                modelPrompt(msg, action: ("重试", { live.installSelected() }))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var transcriptLines: some View {
        if live.lines.isEmpty {
            Text(live.waitingToAttach ? "识别模型正在准备，字幕马上开始…" : "等待说话…")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(live.lines) { line in
                            (Text(line.channel == .mic ? "我  " : "对方  ")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundColor(line.channel == .mic ? Self.micColor : Self.systemColor)
                             + Text(line.text)
                                .font(.system(size: 13.5))
                                .foregroundColor(line.isFinal ? .white : .white.opacity(0.45)))
                                .lineSpacing(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                }
                .onChange(of: live.lines) { _, lines in
                    if let last = lines.last { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
    }

    private func modelPrompt(_ text: String, action: (String, () -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Spacer(minLength: 0)
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let action {
                pillButton(action.0, action: action.1)
            }
            Spacer(minLength: 0)
        }
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
                .frame(width: 24, height: 24)
                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func pillButton(_ title: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 11)
                .frame(height: 26)
                .background(tint?.opacity(0.9) ?? Color.white.opacity(0.1), in: Capsule())
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

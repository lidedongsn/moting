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
    private static let bottomID = "bottom"
    /// 字幕区是否停在最新一行（往上翻看时为 false）
    @State private var following = true

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
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.12)], startPoint: .top, endPoint: .bottom),
                          lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .contextMenu { opacityMenu }
        // 面板带隐藏的标题栏，不忽略安全区内容会被往下挤、底部被裁掉
        .ignoresSafeArea()
    }

    /// 录音结束后：会后精准转写的进度（设计稿：标题 + 百分比、细进度条、说明）
    private var processingView: some View {
        let p = processing.lastRecordedMeetingID.flatMap { processing.progress[$0] } ?? 0
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                switch processing.lastStatus {
                case .done:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("精准转写完成").fontWeight(.semibold)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("精准转写失败").fontWeight(.semibold)
                case .waitingForPower:
                    Image(systemName: "powerplug").foregroundStyle(.secondary)
                    Text("等待接通电源").fontWeight(.semibold)
                case .paused:
                    Image(systemName: "pause.circle.fill").foregroundStyle(.secondary)
                    Text("精准转写已暂停").fontWeight(.semibold)
                default:
                    Image(systemName: "circle.lefthalf.filled").foregroundStyle(Color(hex: 0x7DE3FF))
                    Text("正在精准转写").fontWeight(.semibold)
                }
                Spacer()
                if processing.lastStatus == .running || processing.lastStatus == .queued || processing.lastStatus == .paused {
                    Text("\(Int(p * 100))%").monospacedDigit().foregroundStyle(.white.opacity(0.75))
                }
                iconButton("xmark", help: "关闭（转写在后台继续）") { processing.dismissLastRecorded() }
            }
            .font(.system(size: 12.5))
            .padding(.leading, 14).padding(.trailing, ui.collapsed ? 9 : 12).padding(.top, ui.collapsed ? 0 : 11)
            // 收起时整行居中，点一下展开
            .frame(maxHeight: ui.collapsed ? .infinity : nil)
            .contentShape(Rectangle())
            .onTapGesture { if ui.collapsed { ui.collapsed = false } }
            if !ui.collapsed {
                if processing.lastStatus == .running || processing.lastStatus == .queued || processing.lastStatus == .paused {
                    Capsule().fill(.white.opacity(0.12))
                        .overlay(alignment: .leading) {
                            GeometryReader { g in
                                Capsule().fill(LinearGradient(colors: [Self.micColor, Color(hex: 0x7DE3FF)], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: g.size.width * min(1, max(0.02, p)))
                            }
                        }
                        .frame(height: 4)
                        .padding(.horizontal, 14).padding(.top, 10)
                }
                Text(processingHint)
                    .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 14).padding(.top, 10)
                HStack(spacing: 6) {
                    if let id = processing.lastRecordedMeetingID {
                        switch processing.lastStatus {
                        case .waitingForPower: pillButton("现在处理") { processing.processNow(id) }
                        case .queued, .running: pillButton("❚❚ 暂停") { processing.pause(id) }
                        case .paused: pillButton("▶ 继续") { processing.resume(id) }
                        default: EmptyView()
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 10)
            }
            if !ui.collapsed { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var processingHint: String {
        switch processing.lastStatus {
        case .done: "已替换实时草稿，可以在主窗口查看。"
        case .failed: "可以在主窗口重试。"
        case .waitingForPower: "正在使用电池，接通电源后自动开始。"
        case .paused: "已完成的部分会保留，继续时接着处理。"
        default: "可以关掉这个窗口，完成后会通知你。"
        }
    }

    @ViewBuilder
    private var recordingView: some View {
        if ui.collapsed {
            capsule
        } else {
            VStack(spacing: 0) {
                header
                subtitles
                actions
            }
        }
    }

    private var recDot: some View {
        let c = recorder.state == .paused ? Color.orange : Theme.record
        return Circle().fill(c).frame(width: 8, height: 8)
            .background(Circle().fill(c.opacity(0.25)).frame(width: 14, height: 14))
    }

    /// 展开态头部：红点、计时、两路电平、★、收起
    private var header: some View {
        HStack(spacing: 9) {
            recDot
            Text(recorder.elapsed.clockText).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
            if recorder.state == .paused {
                Text("已暂停").font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
            }
            MiniLevel(level: recorder.levels[.mic] ?? 0, color: Self.micColor)
            MiniLevel(level: recorder.levels[.system] ?? 0, color: Self.systemColor)
            if !recorder.warnings.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .help(recorder.warnings.joined(separator: "\n"))
            }
            Spacer(minLength: 4)
            iconButton("star.fill", help: "标记重点") { recorder.mark() }
            iconButton("minus", help: "收起") { ui.collapsed = true }
        }
        .padding(.leading, 14).padding(.trailing, 12)
        .padding(.top, 11).padding(.bottom, 8)
    }

    /// 收起后的胶囊：红点、计时、最新一句、停止；点文字展开
    private var capsule: some View {
        HStack(spacing: 10) {
            recDot
            Text(recorder.elapsed.clockText).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
            HStack(spacing: 6) {
                if let line = live.lines.last {
                    Text(line.channel == .mic ? "我" : "对方")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(line.channel == .mic ? Self.micColor : Self.systemColor)
                        .fixedSize()
                    // 只截断正文开头，保留最新的字
                    Text(line.text).font(.system(size: 12.5)).lineLimit(1).truncationMode(.head)
                } else {
                    Text(recorder.state == .paused ? "已暂停" : "录音中").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { ui.collapsed = false }
            .help("展开")
            Button { recorder.stop() } label: {
                Image(systemName: "stop.fill").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Theme.record.opacity(0.9), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(recorder.isStopping)
            .help("结束录音")
        }
        .padding(.leading, 14).padding(.trailing, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .padding(.horizontal, 14)
        .padding(.top, 2)
    }

    @ViewBuilder
    private var transcriptLines: some View {
        if live.lines.isEmpty {
            Text(live.waitingToAttach ? "识别模型正在准备，字幕马上开始…" : "等待说话…")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(live.lines) { line in
                                (Text(line.channel == .mic ? "我 " : "对方 ")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundColor(line.channel == .mic ? Self.micColor : Self.systemColor)
                                 + Text(line.text)
                                    .font(.system(size: 13.5))
                                    .foregroundColor(line.isFinal ? .white : .white.opacity(0.45)))
                                    .lineSpacing(3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(line.id)
                            }
                            // 底部哨兵：看得见说明停在最新处，新字幕来了就跟着滚；往上翻看时不打扰
                            Color.clear.frame(height: 1).id(Self.bottomID)
                                .onAppear { following = true }
                                .onDisappear { following = false }
                        }
                    }
                    // 顶部淡出，翻到上面的字幕不会被标题栏生硬切断
                    .mask(VStack(spacing: 0) {
                        LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 14)
                        Color.black
                    })
                    .onChange(of: live.lines) { _, _ in
                        if following { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                    }
                    if !following {
                        Button {
                            following = true
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
                        } label: {
                            Label("回到最新", systemImage: "arrow.down")
                                .font(.system(size: 11.5, weight: .medium))
                                .padding(.horizontal, 10).frame(height: 24)
                                .background(Color(white: 0.18).opacity(0.92), in: Capsule())
                                .overlay(Capsule().strokeBorder(.white.opacity(0.22), lineWidth: 0.5))
                                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 4)
                        .transition(.opacity)
                    }
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
            pillButton("★ 标记") { recorder.mark() }
            if recorder.state == .paused {
                pillButton("▶ 继续") { recorder.resume() }
            } else {
                pillButton("❚❚ 暂停") { recorder.pause() }
            }
            Spacer()
            pillButton(recorder.isStopping ? "正在结束…" : "■ 结束", tint: Theme.record) { recorder.stop() }
                .disabled(recorder.isStopping)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8).padding(.bottom, 12)
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
                .background(tint.map { AnyShapeStyle($0.opacity(0.9)) } ?? AnyShapeStyle(Color.white.opacity(0.1)), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct MiniLevel: View {
    let level: Float
    let color: Color

    var body: some View {
        // 3 根竖条，按电平点亮
        let lit: Int = min(3, Int((level * 50).squareRoot() / 3 * 3.99))
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 2)
                    .fill(i < lit ? color : Color.white.opacity(0.2))
                    .frame(width: 3, height: 5 + CGFloat(i) * 3.5)
            }
        }
        .frame(height: 12)
    }
}

import AppKit
import MotingASR
import MotingCore
import SwiftUI

/// 设置窗口：系统设置样式的左侧分栏
struct SettingsRoot: View {
    static let paneKey = "settings.pane"

    @ObservedObject var live: LiveTranscriptModel
    @ObservedObject var processing: ProcessingModel
    let env: AppEnvironment
    @ObservedObject var recorder: RecordingController
    @StateObject private var downloads: ModelDownloads
    @AppStorage(SettingsRoot.paneKey) private var pane = "general"

    init(live: LiveTranscriptModel, processing: ProcessingModel, env: AppEnvironment, recorder: RecordingController) {
        self.recorder = recorder
        self.live = live
        self.processing = processing
        self.env = env
        _downloads = StateObject(wrappedValue: ModelDownloads(store: env.modelStore))
    }

    private struct Item: Identifiable {
        let id: String, title: String, symbol: String, color: Color
    }

    private let items: [Item] = [
        Item(id: "general", title: L("通用"), symbol: "gearshape.fill", color: .gray),
        Item(id: "models", title: L("识别模型"), symbol: "waveform", color: Theme.me),
        Item(id: "summary", title: L("AI 纪要"), symbol: "sparkles", color: .purple),
        Item(id: "voice", title: L("热词与声纹"), symbol: "person.wave.2.fill", color: .orange),
        Item(id: "storage", title: L("存储"), symbol: "internaldrive.fill", color: .green),
        Item(id: "download", title: L("下载"), symbol: "arrow.down.circle.fill", color: .blue),
    ]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ScrollView {
                Group {
                    switch pane {
                    case "models": ModelsPane(live: live, env: env, downloads: downloads)
                    case "summary": SummaryPane(model: processing.summary)
                    case "voice": VoicePane(env: env, downloads: downloads)
                    case "storage": StoragePane(env: env, live: live)
                    case "download": DownloadPane(env: env)
                    default: GeneralPane(recorder: recorder)
                    }
                }
                .padding(.horizontal, 30)
                .padding(.top, 26)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // 标题栏并入内容区后窗口会高出一截，高度随窗口撑满
        .frame(width: 800)
        .frame(minHeight: 620, maxHeight: .infinity)
        .background(Theme.settingsCanvas)
        .background(WindowChrome())
        .ignoresSafeArea()
    }

    /// 左侧分栏：通高，右边一条竖线和内容隔开，红绿灯落在它的顶部
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(items) { item in
                let on = pane == item.id
                Button { pane = item.id } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(item.color.gradient, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                        Text(item.title).font(.system(size: 13.5, weight: on ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(on ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.top, 52)
        .padding(.bottom, 10)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(Theme.settingsSidebar)
        .overlay(alignment: .trailing) { Divider() }
    }
}

/// 设置窗口外观：隐藏标题、标题栏透明、内容延伸到顶部
/// SwiftUI 重新显示设置窗口时会把标题栏恢复，所以挂到窗口和窗口激活时都重新设置
private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ChromeView() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? ChromeView)?.apply() }

    final class ChromeView: NSView {
        private static let toolbarID = "moting.settings.chrome"
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // 离开窗口时 window 为 nil，在这里一并注销
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let w = window else { return }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didUpdateNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: w, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.apply() }
                })
            }
            apply()
            DispatchQueue.main.async { [weak self] in self?.apply() }
        }

        func apply() {
            guard let w = window else { return }
            if w.titleVisibility != .hidden { w.titleVisibility = .hidden }
            if !w.titlebarAppearsTransparent { w.titlebarAppearsTransparent = true }
            if !w.styleMask.contains(.fullSizeContentView) { w.styleMask.insert(.fullSizeContentView) }
            if w.titlebarSeparatorStyle != .none { w.titlebarSeparatorStyle = .none }
            // 空的统一样式工具栏：标题栏加高，红绿灯下移内缩，和侧栏留出呼吸感
            if w.toolbar == nil || w.toolbar?.identifier != Self.toolbarID { w.toolbar = NSToolbar(identifier: Self.toolbarID) }
            if w.toolbarStyle != .unified { w.toolbarStyle = .unified }
            w.isMovableByWindowBackground = true
        }
    }
}

/// 设置页的标题区
struct PaneHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 24, weight: .semibold, design: .serif))
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .padding(.bottom, 14)
    }
}

/// 设置页里的分组卡片
struct PaneCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .glassCard()
    }
}

func bytesText(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

/// 设置页里的小按钮（设计稿 .btn / .btn.danger / .btn.prim）
struct PaneButtonStyle: ButtonStyle {
    enum Kind { case normal, danger, primary }
    var kind: Kind = .normal

    func makeBody(configuration: Configuration) -> some View {
        let style: AppButtonStyle.Kind = switch kind {
        case .normal: .secondary
        case .danger: .danger
        case .primary: .primary
        }
        return AppButtonStyle(kind: style).makeBody(configuration: configuration)
    }
}

/// 设置页输入框底：半透明圆角，暗色下不再是系统那条黑底
extension View {
    func paneInput() -> some View {
        padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
    }
}

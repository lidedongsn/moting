import AppKit
import MotingASR
import SwiftUI

/// 设置窗口：系统设置样式的左侧分栏
struct SettingsRoot: View {
    static let paneKey = "settings.pane"

    @ObservedObject var live: LiveTranscriptModel
    @ObservedObject var processing: ProcessingModel
    let env: AppEnvironment
    @StateObject private var downloads: ModelDownloads
    @AppStorage(SettingsRoot.paneKey) private var pane = "general"

    init(live: LiveTranscriptModel, processing: ProcessingModel, env: AppEnvironment) {
        self.live = live
        self.processing = processing
        self.env = env
        _downloads = StateObject(wrappedValue: ModelDownloads(store: env.modelStore))
    }

    private struct Item: Identifiable {
        let id: String, title: String, symbol: String, color: Color
    }

    private let items: [Item] = [
        Item(id: "general", title: "通用", symbol: "gearshape.fill", color: .gray),
        Item(id: "models", title: "识别模型", symbol: "waveform", color: Theme.me),
        Item(id: "summary", title: "AI 纪要", symbol: "sparkles", color: .purple),
        Item(id: "voice", title: "热词与声纹", symbol: "person.wave.2.fill", color: .orange),
        Item(id: "storage", title: "存储", symbol: "internaldrive.fill", color: .green),
        Item(id: "download", title: "下载", symbol: "arrow.down.circle.fill", color: .blue),
    ]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ScrollView {
                Group {
                    switch pane {
                    case "models": ModelsPane(live: live, env: env, downloads: downloads)
                    case "summary": SummaryPane()
                    case "voice": VoicePane(env: env, downloads: downloads)
                    case "storage": StoragePane(env: env, live: live)
                    case "download": DownloadPane(env: env)
                    default: GeneralPane()
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
        .background(WindowChrome())
        .ignoresSafeArea()
    }

    /// 浮在窗口内的圆角玻璃侧栏（设计稿 .setside），红绿灯落在它的顶部
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
                            .background(item.color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(item.title).font(.system(size: 13.5, weight: on ? .semibold : .regular))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(on ? Theme.me.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 44)
        .padding(.bottom, 8)
        .frame(width: 212)
        .frame(maxHeight: .infinity)
        .glassCard(radius: 12, material: .thinMaterial)
        .padding([.leading, .vertical], 8)
    }
}

/// 设置窗口外观：隐藏标题、标题栏透明、内容延伸到顶部
private struct WindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.styleMask.insert(.fullSizeContentView)
            w.isMovableByWindowBackground = true
            w.toolbar = nil
        }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// 设置页的标题区
struct PaneHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 22, weight: .bold)).tracking(-0.2)
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
            .glassCard(radius: 12, material: .regularMaterial)
    }
}

func bytesText(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

/// 设置页里的小按钮（设计稿 .btn / .btn.danger / .btn.prim）
struct PaneButtonStyle: ButtonStyle {
    enum Kind { case normal, danger, primary }
    var kind: Kind = .normal
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: kind == .primary ? .semibold : .regular))
            .foregroundStyle(kind == .primary ? Color.white : kind == .danger ? Color(light: 0xD70015, dark: 0xFF6961) : Color.primary)
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(kind == .primary ? AnyShapeStyle(Theme.me) : AnyShapeStyle(Color.primary.opacity(0.07)),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(kind == .primary ? Color.clear : Color.primary.opacity(0.12), lineWidth: 0.5))
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.35)
            .contentShape(Rectangle())
    }
}

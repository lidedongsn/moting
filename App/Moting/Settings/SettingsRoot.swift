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
        NavigationSplitView {
            List(items, selection: $pane) { item in
                Label {
                    Text(item.title)
                } icon: {
                    Image(systemName: item.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(item.color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .tag(item.id)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
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
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 760, height: 560)
    }
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

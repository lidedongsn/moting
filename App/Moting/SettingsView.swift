import AppKit
import MotingASR
import MotingPipeline
import SwiftUI

/// 设置窗口（⌘,）
struct SettingsView: View {
    @ObservedObject var live: LiveTranscriptModel
    let env: AppEnvironment
    @StateObject private var downloads: ModelDownloads

    init(live: LiveTranscriptModel, env: AppEnvironment) {
        self.live = live
        self.env = env
        _downloads = StateObject(wrappedValue: ModelDownloads(store: env.modelStore))
    }

    var body: some View {
        TabView {
            RealtimeSettingsView(live: live, modelsRoot: env.paths.modelsRoot)
                .tabItem { Label("实时字幕", systemImage: "captions.bubble") }
            OfflineSettingsView(env: env, downloads: downloads)
                .tabItem { Label("精准转写", systemImage: "waveform.badge.magnifyingglass") }
            VoiceSettingsView(env: env, downloads: downloads)
                .tabItem { Label("热词与声纹", systemImage: "person.wave.2") }
            DownloadSettingsView(env: env)
                .tabItem { Label("下载", systemImage: "arrow.down.circle") }
        }
        .frame(width: 600)
    }
}

private func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

/// 模型一行：名称、大小、下载进度 / 删除
private struct ModelRow<M: DownloadableModel>: View {
    let model: M
    let subtitle: String?
    @ObservedObject var downloads: ModelDownloads
    var trailing: AnyView? = nil

    var body: some View {
        let installed = downloads.isInstalled(model)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                    Text((installed ? "已下载 · 占用 \(bytes(downloads.usage(model)))" : "未下载 · 约 \(bytes(model.totalSize))")
                         + (subtitle.map { " · \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let p = downloads.progress[model.id] {
                    ProgressView(value: p).frame(width: 90)
                    Text("\(Int(p * 100))%").font(.caption).monospacedDigit().frame(width: 36, alignment: .trailing)
                } else if installed {
                    trailing
                    Button("删除", role: .destructive) { downloads.remove(model) }
                } else {
                    Button("下载") { downloads.install(model) }
                }
            }
            if let err = downloads.errors[model.id] {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
        }
        .id(downloads.revision)
    }
}

/// 设置·精准转写：离线模型选择与辅助模型
struct OfflineSettingsView: View {
    let env: AppEnvironment
    @ObservedObject var downloads: ModelDownloads
    @AppStorage(AppEnvironment.offlineModelKey) private var selectedID = OfflineCatalog.default.id

    var body: some View {
        Form {
            Section {
                ForEach(OfflineCatalog.all) { m in
                    HStack(spacing: 10) {
                        Image(systemName: selectedID == m.id ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(selectedID == m.id ? Color.accentColor : .secondary)
                            .onTapGesture { selectedID = m.id }
                            .help("会后精准转写使用这个模型（未下载会在首次转写时自动下载）")
                        ModelRow(model: m, subtitle: m.supportsHotwords ? "支持热词" : nil, downloads: downloads)
                    }
                }
            } header: {
                Text("离线识别模型")
            } footer: {
                Text("录音结束后用选中的模型对整段录音重新识别。模型越大越准、越慢。").font(.caption).foregroundStyle(.secondary)
            }
            Section("辅助模型（人声检测、说话人分离、声纹、标点）") {
                ForEach(OfflineCatalog.auxiliary) { m in
                    ModelRow(model: m, subtitle: nil, downloads: downloads)
                }
            }
            Section {
                HStack {
                    Text(env.paths.modelsRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("在 Finder 中显示") {
                        try? FileManager.default.createDirectory(at: env.paths.modelsRoot, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([env.paths.modelsRoot])
                    }
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 520)
    }
}

/// 设置·热词与声纹
struct VoiceSettingsView: View {
    let env: AppEnvironment
    @ObservedObject var downloads: ModelDownloads
    @AppStorage(AppEnvironment.offlineModelKey) private var selectedID = OfflineCatalog.default.id
    @State private var hotwords = ""
    @State private var savedHotwords = ""
    @State private var hasVoiceprint = false
    @State private var enrolling = false

    var body: some View {
        Form {
            Section {
                TextEditor(text: $hotwords)
                    .font(.body)
                    .frame(height: 140)
                HStack {
                    if let m = OfflineCatalog.model(id: selectedID), !m.supportsHotwords {
                        Label("当前精准转写模型「\(m.displayName)」不支持热词，可在「精准转写」页换成支持热词的模型。",
                              systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("保存") { saveHotwords() }.disabled(hotwords == savedHotwords)
                }
            } header: {
                Text("热词（每行一个：人名、产品名、术语）")
            } footer: {
                pathFooter(env.paths.hotwordsURL)
            }
            Section {
                HStack {
                    Image(systemName: hasVoiceprint ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark")
                        .foregroundStyle(hasVoiceprint ? .green : .secondary)
                    Text(hasVoiceprint ? "已登记你的声纹" : "还没有登记声纹")
                    Spacer()
                    Button(hasVoiceprint ? "重新登记" : "登记声纹") { enrolling = true }
                    if hasVoiceprint {
                        Button("删除", role: .destructive) {
                            try? FileManager.default.removeItem(at: env.paths.voiceprintURL)
                            refresh()
                        }
                    }
                }
            } header: {
                Text("我的声纹")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("登记后，精准转写会去掉麦克风里旁边无关的人声，只保留你自己说的话。").font(.caption).foregroundStyle(.secondary)
                    pathFooter(env.paths.voiceprintURL)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .sheet(isPresented: $enrolling, onDismiss: refresh) {
            VoiceprintEnrollView(env: env) { enrolling = false }
        }
    }

    private func pathFooter(_ url: URL) -> some View {
        HStack {
            Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer()
            if FileManager.default.fileExists(atPath: url.path) {
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
        }
        .font(.caption)
    }

    private func refresh() {
        hasVoiceprint = FileManager.default.fileExists(atPath: env.paths.voiceprintURL.path)
        savedHotwords = DefaultStepRunner.loadHotwords(env.paths.hotwordsURL).joined(separator: "\n")
        hotwords = savedHotwords
    }

    private func saveHotwords() {
        let words = hotwords.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let url = env.paths.hotwordsURL
        if words.isEmpty {
            try? FileManager.default.removeItem(at: url)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? words.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        refresh()
    }
}

/// 设置·下载：代理
struct DownloadSettingsView: View {
    let env: AppEnvironment
    @AppStorage(AppEnvironment.proxyKey) private var proxy = ""

    var body: some View {
        Form {
            Section {
                TextField("代理地址", text: $proxy, prompt: Text("例如 127.0.0.1:7897，留空表示不用代理"))
                    .onSubmit { env.setProxy(proxy) }
                    .onChange(of: proxy) { _, v in env.setProxy(v) }
            } header: {
                Text("下载代理")
            } footer: {
                Text("模型从 hf-mirror / HuggingFace / GitHub 下载。如果你平时通过 Clash 等代理上网、但没开系统代理，下载可能很慢或失败，在这里填上本机代理地址即可。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

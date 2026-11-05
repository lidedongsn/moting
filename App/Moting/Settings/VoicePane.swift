import AppKit
import MotingASR
import MotingCore
import MotingPipeline
import SwiftUI

/// 设置·热词与声纹
struct VoicePane: View {
    let env: AppEnvironment
    @ObservedObject var downloads: ModelDownloads
    @AppStorage(AppEnvironment.offlineModelKey) private var offlineID = OfflineCatalog.default.id
    @State private var hotwords = ""
    @State private var saved = ""
    @State private var hasVoiceprint = false
    @State private var enrolling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: L("热词与声纹"), subtitle: L("让精准转写认得你们的专有名词，并去掉旁边无关的人声。"))
            Text("热词").font(.headline).padding(.bottom, 8)
            PaneCard {
                VStack(alignment: .leading, spacing: 8) {
                    TextEditor(text: $hotwords)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .frame(height: 120)
                        .paneInput()
                    HStack {
                        if let m = OfflineCatalog.model(id: offlineID), !m.supportsHotwords {
                            Label("当前精准转写模型「\(m.displayName)」不支持热词。", systemImage: "info.circle")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("每行一个：人名、产品名、术语。").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("保存", action: save).buttonStyle(PaneButtonStyle(kind: .primary)).disabled(hotwords == saved)
                    }
                }
                .padding(14)
            }
            Text("我的声纹").font(.headline).padding(.top, 22).padding(.bottom, 8)
            PaneCard {
                HStack(spacing: 12) {
                    Image(systemName: hasVoiceprint ? "checkmark.seal.fill" : "person.crop.circle.badge.questionmark")
                        .font(.title2).foregroundStyle(hasVoiceprint ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hasVoiceprint ? L("已登记你的声纹") : L("还没有登记声纹")).fontWeight(.semibold)
                        Text("登记后，精准转写只保留麦克风里你自己的声音，旁边同事说话会被去掉。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(hasVoiceprint ? L("重新登记") : L("登记声纹")) { enrolling = true }.buttonStyle(PaneButtonStyle())
                    if hasVoiceprint {
                        Button("删除", role: .destructive) {
                            try? FileManager.default.removeItem(at: env.paths.voiceprintURL)
                            refresh()
                        }
                        .buttonStyle(PaneButtonStyle(kind: .danger))
                    }
                }
                .padding(14)
            }
        }
        .onAppear(perform: refresh)
        .sheet(isPresented: $enrolling, onDismiss: refresh) {
            VoiceprintEnrollView(env: env) { enrolling = false }
        }
    }

    private func refresh() {
        hasVoiceprint = FileManager.default.fileExists(atPath: env.paths.voiceprintURL.path)
        saved = DefaultStepRunner.loadHotwords(env.paths.hotwordsURL).joined(separator: "\n")
        hotwords = saved
    }

    private func save() {
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
struct DownloadPane: View {
    let env: AppEnvironment
    @AppStorage(AppEnvironment.proxyKey) private var proxy = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: L("网络"), subtitle: L("模型从 hf-mirror、HuggingFace 或 GitHub 下载。"))
            PaneCard {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("代理地址", text: $proxy, prompt: Text("例如 127.0.0.1:7897，留空表示不用代理"))
                        .textFieldStyle(.plain)
                        .paneInput()
                        .onChange(of: proxy) { _, v in env.setProxy(v) }
                    Text("平时通过 Clash 等代理上网、但没有打开系统代理时，下载可能很慢或失败，在这里填上本机代理地址。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
            }
        }
    }
}

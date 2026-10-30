import AppKit
import MotingASR
import SwiftUI

/// 设置·实时字幕：流式识别模型的下载、删除、选择，以及存放位置
struct RealtimeSettingsView: View {
    @ObservedObject var live: LiveTranscriptModel
    let modelsRoot: URL

    var body: some View {
        Form {
            Section {
                ForEach(ModelCatalog.all) { m in
                    row(m)
                }
            } header: {
                Text("实时识别模型")
            } footer: {
                HStack {
                    Text(modelsRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("在 Finder 中显示") {
                        try? FileManager.default.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
                        NSWorkspace.shared.activateFileViewerSelecting([modelsRoot])
                    }
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ m: StreamingModel) -> some View {
        let installed = live.isInstalled(m)
        return HStack(spacing: 10) {
            Image(systemName: live.selectedModelID == m.id ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(live.selectedModelID == m.id ? Color.accentColor : .secondary)
                .onTapGesture { if installed { live.selectedModelID = m.id } }
                .help(installed ? "设为默认" : "先下载才能设为默认")
            VStack(alignment: .leading, spacing: 2) {
                Text(m.displayName)
                Text(installed ? "已下载 · 占用 \(bytes(live.diskUsage(m)))" : "未下载 · 约 \(bytes(m.totalSize))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let p = live.downloads[m.id] {
                ProgressView(value: p).frame(width: 90)
                Text("\(Int(p * 100))%").font(.caption).monospacedDigit().frame(width: 36, alignment: .trailing)
            } else if installed {
                if live.selectedModelID != m.id {
                    Button("设为默认") { live.selectedModelID = m.id }
                }
                Button("删除", role: .destructive) { live.remove(m) }
            } else {
                Button("下载") { live.install(m) }
            }
        }
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

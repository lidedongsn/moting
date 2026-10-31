import MotingASR
import SwiftUI

/// 设置·识别模型：实时与离线各一组，标出实测准确率与处理速度
struct ModelsPane: View {
    @ObservedObject var live: LiveTranscriptModel
    let env: AppEnvironment
    @ObservedObject var downloads: ModelDownloads
    @AppStorage(AppEnvironment.offlineModelKey) private var offlineID = OfflineCatalog.default.id

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "识别模型",
                       subtitle: "准确率和速度来自在这台 Mac 上对 400 条真实会议语音的实测；没有实测过的模型不显示数字。")
            Text("会中实时字幕").font(.headline).padding(.bottom, 8)
            PaneCard {
                ForEach(Array(ModelCatalog.all.enumerated()), id: \.element.id) { i, m in
                    if i > 0 { Divider().padding(.leading, 44) }
                    row(name: m.displayName, size: m.totalSize, hotwords: false, benchmark: m.benchmark,
                        selected: live.selectedModelID == m.id, installed: live.isInstalled(m),
                        usage: live.diskUsage(m), progress: live.downloads[m.id],
                        select: { live.selectedModelID = m.id }, download: { live.install(m) }, remove: { live.remove(m) })
                }
            }
            Text("会后精准转写").font(.headline).padding(.top, 22).padding(.bottom, 8)
            PaneCard {
                ForEach(Array(OfflineCatalog.all.enumerated()), id: \.element.id) { i, m in
                    if i > 0 { Divider().padding(.leading, 44) }
                    row(name: m.displayName, size: m.totalSize, hotwords: m.supportsHotwords, benchmark: m.benchmark,
                        selected: offlineID == m.id, installed: downloads.isInstalled(m), usage: downloads.usage(m),
                        progress: downloads.progress[m.id], error: downloads.errors[m.id],
                        select: { offlineID = m.id }, download: { downloads.install(m) }, remove: { downloads.remove(m) })
                }
            }
            .id(downloads.revision)
            Text("未下载的离线模型在第一次精准转写时会自动下载。").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
        }
    }

    @ViewBuilder
    private func row(name: String, size: Int64, hotwords: Bool, benchmark: Benchmark?, selected: Bool, installed: Bool,
                     usage: Int64, progress: Double?, error: String? = nil,
                     select: @escaping () -> Void, download: @escaping () -> Void, remove: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Circle()
                    .strokeBorder(selected ? Theme.me : Color.secondary.opacity(0.5), lineWidth: selected ? 5 : 1.5)
                    .frame(width: 16, height: 16)
                    .contentShape(Circle())
                    .onTapGesture(perform: select)
                    .help("选用这个模型")
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).fontWeight(.semibold).lineLimit(1).truncationMode(.tail).help(name)
                    Text([installed ? "已下载 · \(bytesText(usage))" : "约 \(bytesText(size))", hotwords ? "支持热词" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                meter(benchmark).frame(width: 130, alignment: .leading)
                Group {
                    if let p = progress {
                        HStack(spacing: 6) {
                            ProgressView(value: p).frame(width: 60)
                            Text("\(Int(p * 100))%").font(.caption).monospacedDigit()
                        }
                    } else if !installed {
                        Button("下载", action: download).buttonStyle(PaneButtonStyle())
                    } else if !selected {
                        Button("删除", action: remove).buttonStyle(PaneButtonStyle(kind: .danger))
                    } else if let m = benchmark?.minutesPerHour {
                        Text("1 小时会议约 \(Int(m.rounded())) 分钟").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    } else {
                        Text("在用").font(.system(size: 12.5)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 78, alignment: .trailing)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.orange).padding(.leading, 28) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// 准确率条：字错率换算成准确率，条长按 80%–100% 拉开；没实测过的只写"未实测"
    @ViewBuilder
    private func meter(_ b: Benchmark?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(b.map { "准确率 \(String(format: "%.1f", 100 - $0.cer))%" } ?? "准确率 未实测")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
            Capsule().fill(Color.primary.opacity(0.08))
                .overlay(alignment: .leading) {
                    if let b {
                        GeometryReader { g in
                            Capsule().fill(Theme.me).frame(width: g.size.width * max(0.04, min(1, (100 - b.cer - 80) / 20)))
                        }
                    }
                }
                .frame(height: 6)
        }
    }
}

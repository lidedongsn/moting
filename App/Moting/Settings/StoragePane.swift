import AppKit
import MotingASR
import MotingCore
import MotingPipeline
import MotingStorage
import MotingSummary
import SwiftUI

/// 设置·存储：占用多少、放在哪、能不能删
struct StoragePane: View {
    let env: AppEnvironment
    @ObservedObject var live: LiveTranscriptModel
    @AppStorage(AppEnvironment.offlineModelKey) private var offlineID = OfflineCatalog.default.id
    @State private var report = StorageReport(items: [])
    @State private var confirmCleanup = false
    @State private var confirmDeleteAll = false
    @Environment(\.openWindow) private var openWindow

    private var segments: [(String, Int64, Color)] {
        [(L("录音"), report.bytes(.recordings), Theme.me),
         (L("在用模型"), report.bytes(.realtimeModel, inUse: true) + report.bytes(.offlineModel, inUse: true), Theme.them),
         (L("未使用模型"), report.reclaimable, Color.secondary.opacity(0.55)),
         (L("辅助模型"), report.bytes(.auxModel), Color.secondary.opacity(0.35)),
         (L("其他"), report.bytes(.other), Color.secondary.opacity(0.2))]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: L("存储"), subtitle: L("Moting 的所有文件都在一个文件夹里，可以在这里查看和删除。"))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bytesText(report.total)).font(.system(size: 32, weight: .bold)).monospacedDigit()
                Text("共占用").foregroundStyle(.secondary)
            }
            GeometryReader { g in
                HStack(spacing: 0) {
                    ForEach(segments, id: \.0) { _, n, c in
                        Rectangle().fill(c).frame(width: report.total > 0 ? g.size.width * CGFloat(n) / CGFloat(report.total) : 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 12)
            .background(Color.secondary.opacity(0.12))
            .clipShape(Capsule())
            .padding(.vertical, 10)
            HStack(spacing: 14) {
                ForEach(segments.filter { $0.1 > 0 }, id: \.0) { name, n, c in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9)
                        Text("\(name) \(bytesText(n))")
                    }
                }
            }
            .font(.caption).foregroundStyle(.secondary)

            if report.reclaimable > 0 {
                HStack {
                    Text("可以释放 \(bytesText(report.reclaimable))").fontWeight(.semibold)
                    Text("\(report.items.filter { !$0.inUse }.count) 个模型当前没有使用").foregroundStyle(.secondary)
                    Spacer()
                    Button("清理未使用的模型") { confirmCleanup = true }.buttonStyle(PaneButtonStyle(kind: .primary))
                }
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(Theme.me.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.me.opacity(0.25), lineWidth: 0.5))
                .padding(.top, 16)
            }

            PaneCard {
                ForEach(Array(report.items.enumerated()), id: \.element.id) { i, item in
                    if i > 0 { Divider().padding(.leading, 14) }
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(item.name)
                                if item.kind != .recordings && item.kind != .other {
                                    StatusTag(text: usageText(item), tint: item.inUse ? .green : .secondary)
                                }
                            }
                            Text(kindText(item.kind)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(bytesText(item.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        if item.kind == .recordings {
                            Button("查看") {
                                openWindow(id: "main")
                                NSApp.activate(ignoringOtherApps: true)
                            }
                            .buttonStyle(PaneButtonStyle())
                            .frame(width: 56, alignment: .trailing)
                        } else if item.kind == .other {
                            Color.clear.frame(width: 56, height: 1)
                        } else {
                            Button("删除") { remove(item) }
                                .buttonStyle(PaneButtonStyle(kind: .danger))
                                .disabled(item.inUse && item.kind != .auxModel)
                                .frame(width: 56, alignment: .trailing)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .padding(.top, 16)

            HStack {
                Text(env.paths.root.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .textSelection(.enabled).foregroundStyle(.secondary)
                Spacer()
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([env.paths.root]) }.buttonStyle(.link)
            }
            .font(.caption)
            .padding(.top, 12)
            HStack {
                Text("卸载 Moting 时，删除这个文件夹即可清理干净。").foregroundStyle(.secondary)
                Spacer()
                Button("删除 Moting 全部数据…") { confirmDeleteAll = true }.buttonStyle(.plain).foregroundStyle(Color(light: 0xD70015, dark: 0xFF6961))
            }
            .font(.caption)
            .padding(.top, 4)
        }
        .onAppear(perform: refresh)
        .confirmationDialog("清理未使用的模型？", isPresented: $confirmCleanup, titleVisibility: .visible) {
            Button("删除 \(report.items.filter { !$0.inUse }.count) 个模型，释放 \(bytesText(report.reclaimable))", role: .destructive) {
                try? StorageInventory.removeUnusedModels(report, store: env.modelStore)
                refresh()
            }
        } message: {
            Text("在用的模型不会被删除。之后需要时可以在「识别模型」里重新下载。")
        }
        .confirmationDialog("删除 Moting 全部数据？", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("删除全部录音、转写稿、模型、设置和 API Key，然后退出", role: .destructive, action: deleteAll)
        } message: {
            Text("这会永久删除 \(bytesText(report.total)) 的数据，无法恢复。")
        }
    }

    private func usageText(_ item: StorageItem) -> String {
        guard item.inUse else { return L("未使用") }
        switch item.kind {
        case .realtimeModel: return L("实时字幕在用")
        case .offlineModel: return L("会后转写在用")
        default: return L("在用")
        }
    }

    private func kindText(_ k: StorageItem.Kind) -> String {
        switch k {
        case .recordings: L("在主窗口按会议删除")
        case .realtimeModel: L("实时字幕模型")
        case .offlineModel: L("精准转写模型")
        case .auxModel: L("辅助模型（人声检测、说话人分离、声纹、标点）")
        case .other: L("数据库、声纹、热词")
        }
    }

    private func refresh() {
        let paths = env.paths, store = env.modelStore, rt = live.selectedModelID, off = offlineID
        Task.detached {
            let r = StorageInventory.scan(paths: paths, store: store, realtimeID: rt, offlineID: off)
            await MainActor.run { report = r }
        }
    }

    private func remove(_ item: StorageItem) {
        if let m = ModelCatalog.model(id: item.id) { live.remove(m) }
        if let m = OfflineCatalog.model(id: item.id) { try? env.modelStore.remove(m) }
        if let m = OfflineCatalog.auxiliary.first(where: { $0.id == item.id }) { try? env.modelStore.remove(m) }
        refresh()
    }

    /// 删除数据目录、系统替 app 生成的缓存和窗口状态、钥匙串里的 AI 纪要 Key、清空设置，然后退出
    private func deleteAll() {
        let fm = FileManager.default
        try? APIKeyStore.default.deleteAll()
        try? fm.removeItem(at: env.paths.root)
        if let id = Bundle.main.bundleIdentifier {
            for url in AppPaths.systemLeftovers(home: fm.homeDirectoryForCurrentUser, bundleID: id) { try? fm.removeItem(at: url) }
        }
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        NSApp.terminate(nil)
    }
}

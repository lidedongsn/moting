import Foundation
import MotingASR
import MotingCore

/// 设置页里离线模型与辅助模型的下载状态
@MainActor
final class ModelDownloads: ObservableObject {
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var errors: [String: String] = [:]
    /// 安装 / 删除后用于刷新界面
    @Published private(set) var revision = 0
    let store: ModelStore

    init(store: ModelStore) {
        self.store = store
    }

    func isInstalled(_ m: some DownloadableModel) -> Bool { store.isInstalled(m) }
    func usage(_ m: some DownloadableModel) -> Int64 { store.diskUsage(m) }

    func install<M: DownloadableModel>(_ m: M) {
        guard progress[m.id] == nil else { return }
        progress[m.id] = 0
        errors[m.id] = nil
        let store = store
        Task.detached {
            do {
                try await store.install(m) { p in
                    Task { @MainActor [weak self] in if self?.progress[m.id] != nil { self?.progress[m.id] = p } }
                }
                await MainActor.run { [weak self] in
                    self?.progress[m.id] = nil
                    self?.revision += 1
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.progress[m.id] = nil
                    self?.errors[m.id] = L("下载失败：\(error.localizedDescription)。如果你用代理上网，请在「下载」页填写代理地址。")
                }
            }
        }
    }

    func remove(_ m: some DownloadableModel) {
        try? store.remove(m)
        revision += 1
    }
}

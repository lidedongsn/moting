import Foundation
import Testing
import MotingASR
import MotingCore
import MotingStorage
@testable import MotingPipeline

private final class SEnv {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("moting-storage-\(UUID().uuidString)")
    let paths: AppPaths
    let store: ModelStore
    init() throws {
        paths = AppPaths(root: root)
        store = ModelStore(root: paths.modelsRoot)
        // 伪造：两个实时模型、两个离线模型、一个辅助模型（文件大小与目录一致即视为已安装）
        for m in [ModelCatalog.bilingualParaformer, ModelCatalog.bilingualZipformer] as [any DownloadableModel]
            + [OfflineCatalog.senseVoice, OfflineCatalog.paraformerZh] + [OfflineCatalog.vad] {
            try fake(m)
        }
        try paths.ensureMeetingDirectory(UUID())
        let rec = paths.meetingsRoot.appendingPathComponent("a.pcm")
        FileManager.default.createFile(atPath: rec.path, contents: Data(count: 1_000))
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    /// 生成稀疏文件：大小与清单一致但不占真实磁盘
    func fake(_ m: some DownloadableModel) throws {
        let dir = store.directory(for: m)
        for f in m.files {
            let url = dir.appendingPathComponent(f.name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let h = try FileHandle(forWritingTo: url)
            try h.truncate(atOffset: UInt64(f.size))
            try h.close()
        }
    }

    func scan() -> StorageReport {
        StorageInventory.scan(paths: paths, store: store, realtimeID: ModelCatalog.bilingualParaformer.id,
                              offlineID: OfflineCatalog.senseVoice.id)
    }
}

@Test func inUseModelsAreNeverUnused() throws {
    let e = try SEnv()
    let r = e.scan()
    #expect(r.items.first { $0.id == ModelCatalog.bilingualParaformer.id }?.inUse == true)
    #expect(r.items.first { $0.id == OfflineCatalog.senseVoice.id }?.inUse == true)
    #expect(r.items.first { $0.id == OfflineCatalog.vad.id }?.inUse == true)
    #expect(r.items.first { $0.id == ModelCatalog.bilingualZipformer.id }?.inUse == false)
    #expect(r.items.first { $0.id == OfflineCatalog.paraformerZh.id }?.inUse == false)
}

@Test func reclaimableSumsUnused() throws {
    let e = try SEnv()
    let r = e.scan()
    #expect(r.reclaimable == ModelCatalog.bilingualZipformer.totalSize + OfflineCatalog.paraformerZh.totalSize)
    #expect(r.items.contains { $0.kind == .recordings && $0.bytes == 1_000 })
}

@Test func removeUnusedKeepsInUse() throws {
    let e = try SEnv()
    try StorageInventory.removeUnusedModels(e.scan(), store: e.store)
    let after = e.scan()
    #expect(after.reclaimable == 0)
    #expect(e.store.isInstalled(ModelCatalog.bilingualParaformer))
    #expect(e.store.isInstalled(OfflineCatalog.senseVoice))
    #expect(!e.store.isInstalled(OfflineCatalog.paraformerZh))
}

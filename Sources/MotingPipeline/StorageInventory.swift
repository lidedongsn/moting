import Foundation
import MotingASR
import MotingCore
import MotingStorage

public struct StorageItem: Identifiable, Sendable {
    public enum Kind: Sendable, Equatable { case recordings, realtimeModel, offlineModel, auxModel, other }

    public var id: String
    public var name: String
    public var kind: Kind
    public var bytes: Int64
    public var inUse: Bool
}

public struct StorageReport: Sendable {
    public var items: [StorageItem]

    public init(items: [StorageItem]) {
        self.items = items
    }

    public var total: Int64 { items.reduce(0) { $0 + $1.bytes } }
    /// 未使用模型的合计，可以一键清理
    public var reclaimable: Int64 { items.filter { !$0.inUse }.reduce(0) { $0 + $1.bytes } }

    public func bytes(_ kind: StorageItem.Kind, inUse: Bool? = nil) -> Int64 {
        items.filter { $0.kind == kind && (inUse == nil || $0.inUse == inUse) }.reduce(0) { $0 + $1.bytes }
    }
}

/// Moting 数据目录的占用清单：录音、每个已下载的模型、其他（数据库、声纹、热词）
public enum StorageInventory {
    /// realtimeID / offlineID 为当前选用的模型；辅助模型一律算在用
    public static func scan(paths: AppPaths, store: ModelStore, realtimeID: String, offlineID: String) -> StorageReport {
        var items: [StorageItem] = [
            StorageItem(id: "recordings", name: L("录音"), kind: .recordings, bytes: paths.meetingsDiskUsage(), inUse: true),
        ]
        for m in ModelCatalog.all where store.diskUsage(m) > 0 {
            items.append(StorageItem(id: m.id, name: m.displayName, kind: .realtimeModel, bytes: store.diskUsage(m), inUse: m.id == realtimeID))
        }
        for m in OfflineCatalog.all where store.diskUsage(m) > 0 {
            items.append(StorageItem(id: m.id, name: m.displayName, kind: .offlineModel, bytes: store.diskUsage(m), inUse: m.id == offlineID))
        }
        for m in OfflineCatalog.auxiliary where store.diskUsage(m) > 0 {
            items.append(StorageItem(id: m.id, name: m.displayName, kind: .auxModel, bytes: store.diskUsage(m), inUse: true))
        }
        let other = directorySize(paths.root) - items.reduce(0) { $0 + $1.bytes }
        if other > 0 {
            items.append(StorageItem(id: "other", name: L("数据库、声纹与热词"), kind: .other, bytes: other, inUse: true))
        }
        return StorageReport(items: items)
    }

    /// 删除所有未使用的模型；在用的一律不动
    public static func removeUnusedModels(_ report: StorageReport, store: ModelStore) throws {
        for item in report.items where !item.inUse {
            if let m = ModelCatalog.model(id: item.id) { try store.remove(m) }
            if let m = OfflineCatalog.model(id: item.id) { try store.remove(m) }
        }
    }

    private static func directorySize(_ dir: URL) -> Int64 {
        let keys: [URLResourceKey] = [.fileSizeKey, .isRegularFileKey]
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
        }
        return total
    }
}

import Foundation
import Testing
import MotingStorage
@testable import MotingASR

/// 真实网络下载模型到正式模型目录（之后可在设置中删除），仅在 MOTING_NET_IT=1 时运行。
/// MOTING_NET_MODELS 可指定模型 id（逗号分隔），默认只装默认模型
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOTING_NET_IT"] == "1"), .timeLimit(.minutes(30)))
func installsModelsFromNetwork() async throws {
    let store = ModelStore(root: AppPaths.default.modelsRoot)
    let ids = ProcessInfo.processInfo.environment["MOTING_NET_MODELS"]?.split(separator: ",").map(String.init)
        ?? [ModelCatalog.default.id]
    for id in ids {
        let m = try #require(ModelCatalog.model(id: id))
        let t0 = Date()
        try await store.install(m) { _ in }
        print("\(m.id) 安装完成，\(m.totalSize / 1_048_576)MB，用时 \(Int(Date().timeIntervalSince(t0))) 秒")
        #expect(store.isInstalled(m))
    }
}

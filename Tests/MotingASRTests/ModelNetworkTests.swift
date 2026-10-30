import Foundation
import Testing
import MotingStorage
@testable import MotingASR

/// 真实网络下载模型到正式模型目录（之后可在设置中删除），仅在 MOTING_NET_IT=1 时运行。
/// MOTING_NET_MODELS 可指定模型 id（逗号分隔），默认只装默认模型
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOTING_NET_IT"] == "1"), .timeLimit(.minutes(30)))
func installsModelsFromNetwork() async throws {
    // 终端里通常有代理环境变量（系统代理可能关着），测试时用它
    let env = ProcessInfo.processInfo.environment
    let proxy = (env["https_proxy"] ?? env["HTTPS_PROXY"]).flatMap(URL.init(string:))
    let store = ModelStore(root: AppPaths.default.modelsRoot, proxy: proxy)
    let ids = ProcessInfo.processInfo.environment["MOTING_NET_MODELS"]?.split(separator: ",").map(String.init)
        ?? [ModelCatalog.default.id]
    for id in ids {
        let m: any DownloadableModel = try #require(
            ModelCatalog.model(id: id) ?? OfflineCatalog.model(id: id)
                ?? OfflineCatalog.auxiliary.first { $0.id == id } as (any DownloadableModel)?)
        let t0 = Date()
        try await store.install(m) { _ in }
        print("\(m.id) 安装完成，\(m.totalSize / 1_048_576)MB，用时 \(Int(Date().timeIntervalSince(t0))) 秒")
        let installed = store.isInstalled(m)
        #expect(installed)
    }
}

import CryptoKit
import Foundation
import Testing
@testable import MotingASR

/// 临时目录：<tmp>/mirrorA、<tmp>/mirrorB、<tmp>/models，用完删除
private final class Sandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("moting-modelstore-\(UUID().uuidString)")
    var mirrorA: URL { root.appendingPathComponent("mirrorA") }
    var mirrorB: URL { root.appendingPathComponent("mirrorB") }
    var models: URL { root.appendingPathComponent("models") }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// 在镜像里放文件，返回对应的 ModelFile
    func publish(_ mirror: URL, repo: String, name: String, content: String) throws -> ModelFile {
        let dir = mirror.appendingPathComponent(repo).appendingPathComponent("resolve/main")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = Data(content.utf8)
        try data.write(to: dir.appendingPathComponent(name))
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ModelFile(name: name, sha256: sha, size: Int64(data.count))
    }
}

private func model(_ files: [ModelFile]) -> StreamingModel {
    StreamingModel(id: "test-model", displayName: "测试", repo: "org/test", kind: .transducer,
                   files: files, roles: [:])
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    func add(_ v: Double) { lock.withLock { values.append(v) } }
    var last: Double? { lock.withLock { values.last } }
}

@Test func installsAndVerifies() async throws {
    let s = Sandbox()
    let files = [try s.publish(s.mirrorA, repo: "org/test", name: "a.onnx", content: "aaaa"),
                 try s.publish(s.mirrorA, repo: "org/test", name: "tokens.txt", content: "你 1\n好 2\n")]
    let store = ModelStore(root: s.models, mirrors: [s.mirrorA])
    let m = model(files)
    #expect(!store.isInstalled(m))
    let progress = ProgressLog()
    try await store.install(m) { progress.add($0) }
    #expect(store.isInstalled(m))
    #expect(progress.last == 1.0)
    #expect(store.diskUsage(m) == files.reduce(0) { $0 + $1.size })
}

@Test func fallsBackToSecondMirror() async throws {
    let s = Sandbox()
    let f = try s.publish(s.mirrorB, repo: "org/test", name: "a.onnx", content: "bbbb")
    let store = ModelStore(root: s.models, mirrors: [s.mirrorA, s.mirrorB])
    try await store.install(model([f])) { _ in }
    #expect(store.isInstalled(model([f])))
}

@Test func checksumMismatchRemovesFile() async throws {
    let s = Sandbox()
    var f = try s.publish(s.mirrorA, repo: "org/test", name: "a.onnx", content: "cccc")
    f.sha256 = String(repeating: "0", count: 64)
    let store = ModelStore(root: s.models, mirrors: [s.mirrorA])
    let m = model([f])
    await #expect(throws: ModelStoreError.checksumMismatch("a.onnx")) { try await store.install(m) { _ in } }
    let dir = store.directory(for: m)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.onnx").path))
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.onnx.part").path))
    #expect(!store.isInstalled(m))
}

@Test func skipsVerifiedFiles() async throws {
    let s = Sandbox()
    let f = try s.publish(s.mirrorA, repo: "org/test", name: "a.onnx", content: "dddd")
    let store = ModelStore(root: s.models, mirrors: [s.mirrorA])
    try await store.install(model([f])) { _ in }
    try FileManager.default.removeItem(at: s.mirrorA)
    try await store.install(model([f])) { _ in }   // 镜像已不存在，但无需再下载
    #expect(store.isInstalled(model([f])))
}

@Test func removeDeletesDirectory() async throws {
    let s = Sandbox()
    let f = try s.publish(s.mirrorA, repo: "org/test", name: "a.onnx", content: "eeee")
    let store = ModelStore(root: s.models, mirrors: [s.mirrorA])
    let m = model([f])
    try await store.install(m) { _ in }
    try store.remove(m)
    #expect(!FileManager.default.fileExists(atPath: store.directory(for: m).path))
    #expect(store.diskUsage(m) == 0)
}

@Test func catalogModelsAreComplete() {
    for m in ModelCatalog.all {
        #expect(!m.files.isEmpty)
        for role in m.roles.values { #expect(m.files.contains { $0.name == role }, "\(m.id) 缺少 \(role)") }
        #expect(m.roles["tokens"] == "tokens.txt")
    }
    #expect(ModelCatalog.all.contains(ModelCatalog.default))
}

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

// MARK: - 离线 / 辅助模型：直链与压缩包来源

private func sha(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// 用 tar 现做一个 tar.bz2：包内目录 prefix/ 下放若干文件
private func makeArchive(in dir: URL, prefix: String, files: [String: String]) throws -> (URL, String, Int64) {
    let staging = dir.appendingPathComponent("staging")
    for (name, content) in files {
        let url = staging.appendingPathComponent(prefix).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(content.utf8).write(to: url)
    }
    let archive = dir.appendingPathComponent("pkg.tar.bz2")
    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["-cjf", archive.path, "-C", staging.path, prefix]
    try tar.run()
    tar.waitUntilExit()
    let data = try Data(contentsOf: archive)
    return (archive, sha(data), Int64(data.count))
}

private func file(_ name: String, _ content: String) -> ModelFile {
    ModelFile(name: name, sha256: sha(Data(content.utf8)), size: Int64(content.utf8.count))
}

@Test func installsFromArchiveExtractingOnlyListedFiles() async throws {
    let s = Sandbox()
    try FileManager.default.createDirectory(at: s.root, withIntermediateDirectories: true)
    let (archive, digest, size) = try makeArchive(in: s.root, prefix: "pkg-1",
                                                  files: ["model.onnx": "mmmm", "tok/vocab.json": "{}", "README.md": "说明"])
    let m = AuxModel(id: "aux-test", displayName: "测试",
                     source: .githubArchive(url: archive, sha256: digest, size: size, stripPrefix: "pkg-1"),
                     files: [file("model.onnx", "mmmm"), file("tok/vocab.json", "{}")])
    let store = ModelStore(root: s.models)
    try await store.install(m) { _ in }
    #expect(store.isInstalled(m))
    let dir = store.directory(for: m)
    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("README.md").path))
    #expect(store.diskUsage(m) == 6)
}

@Test func archiveChecksumMismatchLeavesNothing() async throws {
    let s = Sandbox()
    try FileManager.default.createDirectory(at: s.root, withIntermediateDirectories: true)
    let (archive, _, size) = try makeArchive(in: s.root, prefix: "pkg-2", files: ["model.onnx": "mmmm"])
    let m = AuxModel(id: "aux-bad", displayName: "测试",
                     source: .githubArchive(url: archive, sha256: String(repeating: "0", count: 64), size: size, stripPrefix: "pkg-2"),
                     files: [file("model.onnx", "mmmm")])
    let store = ModelStore(root: s.models)
    await #expect(throws: ModelStoreError.checksumMismatch("pkg.tar.bz2")) { try await store.install(m) { _ in } }
    #expect(!store.isInstalled(m))
    #expect(store.diskUsage(m) == 0)
}

@Test func installsDirectFilesIntoSubdirectories() async throws {
    let s = Sandbox()
    let base = s.root.appendingPathComponent("direct")
    try FileManager.default.createDirectory(at: base.appendingPathComponent("tokenizer"), withIntermediateDirectories: true)
    try Data("vvvv".utf8).write(to: base.appendingPathComponent("tokenizer/vocab.json"))
    let m = AuxModel(id: "aux-direct", displayName: "测试", source: .direct(baseURL: base),
                     files: [file("tokenizer/vocab.json", "vvvv")])
    let store = ModelStore(root: s.models)
    try await store.install(m) { _ in }
    #expect(store.isInstalled(m))
    #expect(store.diskUsage(m) == 4)
}

@Test func offlineCatalogIsComplete() {
    for m in OfflineCatalog.all {
        #expect(!m.files.isEmpty)
        for name in m.roles.values where !name.hasSuffix("/") {
            #expect(m.files.contains { $0.name == name }, "\(m.id) 缺少 \(name)")
        }
    }
    #expect(OfflineCatalog.all.contains(OfflineCatalog.default))
    for aux in [OfflineCatalog.vad, OfflineCatalog.segmentation, OfflineCatalog.embedding, OfflineCatalog.punctuation] {
        #expect(!aux.files.isEmpty)
        #expect(aux.files.allSatisfy { $0.sha256.count == 64 && $0.size > 0 })
    }
}

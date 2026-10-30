import Foundation
import Testing
import MotingStorage
@testable import MotingASR

@Test func cosineOfIdenticalIsOne() {
    #expect(abs(VoiceprintMatcher.cosine([1, 2, 3], [1, 2, 3]) - 1) < 1e-6)
    #expect(abs(VoiceprintMatcher.cosine([1, 0], [0, 1])) < 1e-6)
    #expect(VoiceprintMatcher.cosine([], []) == 0)
}

@Test func saveLoadRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("moting-vp-\(UUID().uuidString)/me.f32")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let e: [Float] = [0.1, -0.2, 0.3]
    try VoiceprintMatcher.save(e, to: url)
    #expect(try VoiceprintMatcher.load(url) == e)
}

@Test func voiceprintPathIsUnderAppSupport() {
    let p = AppPaths(root: URL(fileURLWithPath: "/tmp/x"))
    #expect(p.voiceprintURL.path == "/tmp/x/voiceprint/me.f32")
}

/// 两个不同的系统中文声音：同一声音两句的相似度应高于不同声音。仅在 MOTING_ASR_IT=1 时运行
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOTING_ASR_IT"] == "1"))
func sameSpeakerScoresHigherThanDifferent() throws {
    let store = ModelStore(root: AppPaths.default.modelsRoot)
    let m = try VoiceprintMatcher(embeddingModel: OfflineCatalog.embedding, directory: store.directory(for: OfflineCatalog.embedding))
    func say(_ voice: String, _ text: String) throws -> [Float] {
        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("moting-vp-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", wav.path, "--data-format=LEI16@16000", text]
        try p.run()
        p.waitUntilExit()
        return try readWav16k(wav)
    }
    let a1 = try m.embedding(say("Tingting", "今天下午三点开会，讨论接口文档的问题"))
    let a2 = try m.embedding(say("Tingting", "这个版本先不做导出功能，下周再说"))
    let b1 = try m.embedding(say("Meijia", "这个版本先不做导出功能，下周再说"))
    let same = VoiceprintMatcher.cosine(a1, a2), diff = VoiceprintMatcher.cosine(a1, b1)
    print("同一声音 \(same)，不同声音 \(diff)")
    #expect(same > diff)
}

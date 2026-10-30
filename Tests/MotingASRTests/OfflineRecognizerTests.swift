import Foundation
import Testing
import MotingStorage
@testable import MotingASR

@Test func segmenterRequiresModel() {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("moting-none-\(UUID().uuidString).onnx")
    #expect(throws: OfflineASRError.modelMissing(missing.lastPathComponent)) { try VoiceSegmenter(vadModel: missing) }
}

@Test func offlineRecognizerRequiresModel() throws {
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent("moting-empty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: empty) }
    #expect(throws: OfflineASRError.self) { try SherpaOfflineRecognizer(model: OfflineCatalog.senseVoice, directory: empty, hotwords: []) }
}

/// 用 say 合成两句中文、中间 2 秒静音：VAD 切成 2 段，默认离线模型都能识别，标点模型能加标点。
/// 需要已安装 VAD、默认离线模型与标点模型，仅在 MOTING_ASR_IT=1 时运行
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOTING_ASR_IT"] == "1"))
func segmentsAndRecognizesTTS() throws {
    let store = ModelStore(root: AppPaths.default.modelsRoot)
    let a = try ttsSamples("今天的会议主要讨论离线转写的效果")
    let b = try ttsSamples("下周三之前把接口文档定下来")
    let audio = a + [Float](repeating: 0, count: 32_000) + b + [Float](repeating: 0, count: 16_000)

    let segmenter = try VoiceSegmenter(vadModel: store.directory(for: OfflineCatalog.vad).appendingPathComponent("silero_vad.onnx"))
    var spans: [SpeechSpan] = []
    try segmenter.segment(reader: { off, n in Array(audio[off..<min(off + n, audio.count)]) }, total: audio.count) { spans.append($0) }
    #expect(spans.count == 2)

    let m = OfflineCatalog.default
    let r = try SherpaOfflineRecognizer(model: m, directory: store.directory(for: m), hotwords: [])
    let texts = try spans.map { try r.recognize($0.samples) }
    print("离线识别：\(texts)，起点 \(spans.map { Double($0.start) / 16_000 })")
    #expect(texts.allSatisfy { !$0.isEmpty })

    let p = try Punctuator(model: OfflineCatalog.punctuation, directory: store.directory(for: OfflineCatalog.punctuation))
    let punct = p.punctuate("今天的会议主要讨论离线转写的效果下周三之前把接口文档定下来")
    print("加标点：\(punct)")
    #expect(punct.contains("，") || punct.contains("。"))
}

func ttsSamples(_ text: String) throws -> [Float] {
    let wav = FileManager.default.temporaryDirectory.appendingPathComponent("moting-tts-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: wav) }
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", "Tingting", "-o", wav.path, "--data-format=LEI16@16000", text]
    try say.run()
    say.waitUntilExit()
    return try readWav16k(wav)
}

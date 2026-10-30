import Foundation
import Testing
import MotingCore
import MotingStorage
@testable import MotingASR

private let block = [Float](repeating: 0, count: 1_600)

/// 脚本顺序：第一个 makeStream 给 mic，第二个给 system
private func make(_ mic: [FakeRecognizer.Step], _ system: [FakeRecognizer.Step] = []) -> (LiveTranscriber, EventLog) {
    let log = EventLog()
    let t = LiveTranscriber(recognizer: FakeRecognizer([mic, system]), versionID: UUID()) { log.add($0) }
    return (t, log)
}

@Test func partialThenFinalWithMeetingTimes() {
    let (t, log) = make([.init(text: "你"), .init(text: "你好"), .init(text: "你好", endpoint: true)])
    t.feed(.mic, block, startSample: 0)
    t.feed(.mic, block, startSample: 1_600)
    t.feed(.mic, block, startSample: 3_200)
    t.waitUntilIdle()
    #expect(log.partialTexts == ["你", "你好"])
    let f = try! #require(log.finals.first)
    #expect(log.finals.count == 1)
    #expect(f.text == "你好")
    #expect(f.channel == .mic)
    #expect(f.start == 0)
    #expect(abs(f.end - 0.3) < 1e-9)
}

@Test func emptyEndpointProducesNoSegment() {
    let (t, log) = make([.init(text: ""), .init(text: "", endpoint: true), .init(text: "")])
    for i in 0..<3 { t.feed(.mic, block, startSample: i * 1_600) }
    t.waitUntilIdle()
    #expect(log.all.isEmpty)
}

@Test func channelsAreIndependent() {
    let (t, log) = make([.init(text: "我说", endpoint: true)],
                        [.init(text: "你"), .init(text: "你说", endpoint: true)])
    t.feed(.mic, block, startSample: 16_000)
    t.feed(.system, block, startSample: 0)
    t.feed(.system, block, startSample: 1_600)
    t.waitUntilIdle()
    let mic = log.finals.first { $0.channel == .mic }
    let sys = log.finals.first { $0.channel == .system }
    #expect(mic?.text == "我说")
    #expect(mic?.start == 1.0)
    #expect(sys?.text == "你说")
    #expect(sys?.start == 0)
    #expect(abs((sys?.end ?? 0) - 0.2) < 1e-9)
}

@Test func secondSentenceStartsAfterEndpoint() {
    let (t, log) = make([.init(text: "一", endpoint: true), .init(text: "二"), .init(text: "二", endpoint: true)])
    for i in 0..<3 { t.feed(.mic, block, startSample: i * 1_600) }
    t.waitUntilIdle()
    #expect(log.finals.map(\.text) == ["一", "二"])
    #expect(log.finals.last?.start == 0.1)
}

@Test func finishFlushesPartial() {
    let (t, log) = make([.init(text: "还没说完")])
    t.feed(.mic, block, startSample: 0)
    t.finish()
    t.waitUntilIdle()
    #expect(log.finals.map(\.text) == ["还没说完"])
}

/// app 判断"不建转写器、只录音"的依据：模型未安装时 isInstalled 为 false，且创建识别器会抛错
@Test func transcriberWithoutModelIsInert() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("moting-nomodel-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ModelStore(root: root)
    #expect(!store.isInstalled(ModelCatalog.default))
    #expect(throws: RecognizerError.self) {
        try SherpaRecognizer(model: ModelCatalog.default, directory: store.directory(for: ModelCatalog.default))
    }
}

/// 真实模型端到端：用系统 TTS 合成一段中文，经 LiveTranscriber 转写，仅在 MOTING_ASR_IT=1 时运行
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOTING_ASR_IT"] == "1"))
func liveTranscriberWithRealModel() throws {
    let wav = FileManager.default.temporaryDirectory.appendingPathComponent("moting-tts-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: wav) }
    let say = Process()
    say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
    say.arguments = ["-v", "Tingting", "-o", wav.path, "--data-format=LEI16@16000", "今天的会议主要讨论实时字幕的效果。下周三之前把接口文档定下来。"]
    try say.run()
    say.waitUntilExit()
    var samples = try readWav16k(wav)
    samples += [Float](repeating: 0, count: 48_000)   // 尾部 3 秒静音，触发端点
    let m = ModelCatalog.default
    let r = try SherpaRecognizer(model: m, directory: ModelStore(root: AppPaths.default.modelsRoot).directory(for: m))
    let log = EventLog()
    let t = LiveTranscriber(recognizer: r, versionID: UUID()) { log.add($0) }
    let t0 = Date()
    var i = 0
    while i < samples.count {
        // 20ms 一块，和真实采集一致；走麦克风一路，同时验证近场门限不误伤正常说话
        t.feed(.mic, Array(samples[i..<min(i + 320, samples.count)]), startSample: i)
        i += 320
    }
    t.finish()
    t.waitUntilIdle()
    let cost = Date().timeIntervalSince(t0)
    let audio = Double(samples.count) / 16_000
    print("最终文字：\(log.finals.map(\.text))")
    print("片段时间：\(log.finals.map { String(format: "%.2f-%.2f", $0.start, $0.end) })")
    print(String(format: "音频 %.1f 秒，识别耗时 %.2f 秒，RTF %.3f", audio, cost, cost / audio))
    #expect(!log.finals.isEmpty)
}

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

@Test func finishDecodesTailBeforeFinal() {
    // 结束时识别器里还有没出结果的尾音：应补尾、标记输入结束、再解码后定稿
    let (t, log) = make([.init(text: "你"), .init(text: "你好吗")])
    t.feed(.mic, block, startSample: 0)
    t.finishAndWait()
    #expect(log.finals.map(\.text) == ["你好吗"])
}

@Test func speakerEchoIsRemovedBeforeMicRecognition() {
    // 外放：麦克风录进了扬声器里对方的声音（晚 30ms、减半）。送进"我"识别器的应大幅减弱
    var g: UInt64 = 42
    let n = 8 * 16_000
    let far: [Float] = (0..<n).map { i in
        g = g &* 6364136223846793005 &+ 1442695040888963407
        let noise = Float(Int64(bitPattern: g >> 11) % 2000) / 1000 - 1
        return noise * (max(0, sin(Float(i) / 16_000 * 2 * .pi * 2.3)) * 0.6 + 0.05) * 0.5
    }
    let mic: [Float] = (0..<n).map { $0 >= 480 ? far[$0 - 480] * 0.5 : 0 }
    let rec = FakeRecognizer([[], []])
    let t = LiveTranscriber(recognizer: rec, versionID: UUID()) { _ in }
    for p in stride(from: 0, to: n, by: 1_600) {
        t.feed(.system, Array(far[p..<p + 1_600]), startSample: p)
        t.feed(.mic, Array(mic[p..<p + 1_600]), startSample: p)
    }
    t.waitUntilIdle()
    let heard = rec.streams[0].accepted
    let tail = { (x: [Float]) -> Double in
        let s = x.suffix(2 * 16_000)
        return s.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, s.count))
    }
    let reductionDB = 10 * log10(tail(mic) / max(tail(heard), 1e-12))
    #expect(heard.count > n - 16_000, "麦克风不应被卡住")
    #expect(reductionDB > 15, "回声只压低了 \(reductionDB) dB")
}

/// 实测：把一场外放录音的两路文件按录音时的方式送进实时识别，打印两路识别出的文字。
/// MOTING_AEC_DIR=会议目录 [MOTING_AEC_MODEL=模型 id] swift test --filter recordedMeetingLive
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOTING_AEC_DIR"] != nil))
func recordedMeetingLiveTranscript() throws {
    let env = ProcessInfo.processInfo.environment
    let dir = URL(fileURLWithPath: env["MOTING_AEC_DIR"]!)
    func load(_ name: String) throws -> [Float] {
        try Data(contentsOf: dir.appendingPathComponent(name)).withUnsafeBytes { r in
            r.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_768 }
        }
    }
    let mic = try load("mic.pcm"), sys = try load("system.pcm")
    let m = ModelCatalog.all.first { $0.id == env["MOTING_AEC_MODEL"] } ?? ModelCatalog.default
    let r = try SherpaRecognizer(model: m, directory: ModelStore(root: AppPaths.default.modelsRoot).directory(for: m))
    let log = EventLog()
    let t = LiveTranscriber(recognizer: r, versionID: UUID()) { log.add($0) }
    let n = min(mic.count, sys.count)
    for p in stride(from: 0, to: n - 320, by: 320) {
        t.feed(.system, Array(sys[p..<p + 320]), startSample: p)
        t.feed(.mic, Array(mic[p..<p + 320]), startSample: p)
    }
    t.finish()
    t.waitUntilIdle()
    for s in log.finals { print(String(format: "%@ %6.1f-%6.1f %@", s.channel == .mic ? "我  " : "对方", s.start, s.end, s.text)) }
}

@Test func micLineRepeatingSpeakerIsRetracted() {
    // 外放回声被识别成"我"：与同时段"对方"文字大部分相同，不出最终句，已显示的草稿撤回
    let (t, log) = make([.init(text: "第一件事"), .init(text: "第一件是接口文档"), .init(text: "第一件是接口文档在周三定稿", endpoint: true)],
                        [.init(text: "第一件事"), .init(text: "第一件事接口文档"), .init(text: "第一件事接口文档需要在周三之前定稿", endpoint: true)])
    for i in 0..<3 {
        t.feed(.system, block, startSample: i * 1_600)
        t.feed(.mic, block, startSample: i * 1_600)
    }
    t.finish()
    t.waitUntilIdle()
    #expect(log.finals.map(\.channel) == [.system])
    #expect(!log.partialTexts.contains("第一件是接口文档"))
}

@Test func ownReplyDuringSpeakerIsKept() {
    let (t, log) = make([.init(text: "好的我周二给"), .init(text: "好的我周二给你", endpoint: true)],
                        [.init(text: "接口文档"), .init(text: "接口文档周三定稿", endpoint: true)])
    for i in 0..<2 {
        t.feed(.system, block, startSample: i * 1_600)
        t.feed(.mic, block, startSample: i * 1_600)
    }
    t.finish()
    t.waitUntilIdle()
    #expect(log.finals.map(\.text).contains("好的我周二给你"))
}

import Foundation
import MotingStorage
import Testing
@testable import MotingASR

/// 按 protobuf 编码拼一个最小的 sentencepiece 模型
private func varint(_ v: Int) -> Data {
    var v = v, out = Data()
    while v >= 0x80 { out.append(UInt8(v & 0x7F | 0x80)); v >>= 7 }
    out.append(UInt8(v))
    return out
}

private func piece(_ text: String, _ score: Float) -> Data {
    let utf8 = Data(text.utf8)
    var body = Data([0x0A]) + varint(utf8.count) + utf8   // 1: piece
    body.append(0x15)                                     // 2: score（32 位浮点）
    withUnsafeBytes(of: score.bitPattern.littleEndian) { body.append(contentsOf: $0) }
    body += Data([0x18, 0x01])                            // 3: type（要被跳过）
    return Data([0x0A]) + varint(body.count) + body       // ModelProto 1: pieces
}

@Test func convertsSentencePieceModelToTextVocab() throws {
    // 后面跟一个无关字段（2: trainer_spec），要能跳过
    let model = piece("<unk>", 0) + piece("▁HELLO", -1.5) + Data([0x12, 0x02, 0x08, 0x01])
    #expect(try BPEVocab.text(fromModel: model) == "<unk> 0.0\n▁HELLO -1.5\n")
}

@Test func garbageModelIsAnErrorNotACrash() {
    #expect(throws: OfflineASRError.self) { try BPEVocab.text(fromModel: Data([0xFF, 0xFF, 0xFF])) }
    #expect(throws: OfflineASRError.self) { try BPEVocab.text(fromModel: Data()) }
}

@Test func generatesVocabFileOnceNextToTheModel() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("moting-bpe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = dir.appendingPathComponent("bpe.model")
    try piece("A", -2).write(to: model)
    let vocab = try BPEVocab.ensure(modelAt: model)
    #expect(vocab.lastPathComponent == "bpe.vocab")
    #expect(try String(contentsOf: vocab, encoding: .utf8) == "A -2.0\n")
}

/// 真实模型带热词加载并识别（原来这里识别库会直接退出进程），需要已安装 X-ASR 和标点模型
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOTING_HOTWORD_IT"] == "1"))
func realTransducerLoadsWithHotwords() throws {
    let m = OfflineCatalog.xasrTransducer
    let store = ModelStore(root: AppPaths.default.modelsRoot)
    let r = try SherpaOfflineRecognizer(model: m, directory: store.directory(for: m), hotwords: ["谢之遥", "Moting"])
    let samples = (0..<32_000).map { Float(sin(Double($0) * 0.05)) * 0.1 }
    _ = try r.recognize(samples)
}

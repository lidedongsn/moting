import Foundation
import Testing
import MotingStorage
@testable import MotingASR

/// 读取 16kHz 单声道 16 位 PCM WAV（找 data 块）
func readWav16k(_ url: URL) throws -> [Float] {
    let d = try Data(contentsOf: url)
    var i = 12
    while i + 8 <= d.count {
        let id = String(decoding: d[i..<i + 4], as: UTF8.self)
        let size = Int(d[i + 4]) | Int(d[i + 5]) << 8 | Int(d[i + 6]) << 16 | Int(d[i + 7]) << 24
        if id == "data" {
            let body = d[(i + 8)..<min(d.count, i + 8 + size)]
            return body.withUnsafeBytes { raw in
                raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
            }
        }
        i += 8 + size + (size & 1)
    }
    return []
}

/// 把识别器跑完一段音频，返回所有句子拼起来的文字
func transcribe(_ r: StreamingRecognizing, _ samples: [Float]) -> String {
    let s = r.makeStream()
    var out: [String] = []
    var i = 0
    while i < samples.count {
        s.accept(Array(samples[i..<min(i + 1600, samples.count)]))
        s.decode()
        if s.isEndpoint {
            if !s.text.isEmpty { out.append(s.text) }
            s.reset()
        }
        i += 1600
    }
    s.accept([Float](repeating: 0, count: 8000))   // 尾部补 0.5 秒静音，让最后一句出来
    s.decode()
    if !s.text.isEmpty { out.append(s.text) }
    return out.joined(separator: " ")
}

@Test func missingModelThrows() throws {
    let empty = FileManager.default.temporaryDirectory.appendingPathComponent("moting-empty-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: empty) }
    #expect(throws: RecognizerError.self) { try SherpaRecognizer(model: ModelCatalog.default, directory: empty) }
}

/// 需要已安装默认模型与网络（下载 1 个测试音频到临时目录），仅在 MOTING_ASR_IT=1 时运行
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOTING_ASR_IT"] == "1"))
func recognizesBundledWav() async throws {
    let m = ModelCatalog.default
    let dir = ModelStore(root: AppPaths.default.modelsRoot).directory(for: m)
    let tmp = try await downloadTestWav(repo: m.repo, name: "1.wav")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let r = try SherpaRecognizer(model: m, directory: dir)
    let text = transcribe(r, try readWav16k(tmp))
    print("识别结果：\(text)")
    #expect(!text.isEmpty)
}

/// 下载模型仓库自带的测试音频，HuggingFace 超时则换 hf-mirror
func downloadTestWav(repo: String, name: String) async throws -> URL {
    var lastError: Error = URLError(.unknown)
    for host in ["https://huggingface.co", "https://hf-mirror.com"] {
        var req = URLRequest(url: URL(string: "\(host)/\(repo)/resolve/main/test_wavs/\(name)")!)
        req.timeoutInterval = 30
        do {
            let (tmp, _) = try await URLSession.shared.download(for: req)
            return tmp
        } catch {
            lastError = error
        }
    }
    throw lastError
}

import Darwin
import Foundation
import Testing
import MotingStorage
@testable import MotingASR

/// 会议测试集评测：对 MOTING_BENCH_DIR/refs.tsv 中每条（wav/<id>.wav）识别，
/// 结果写到 out/<模型>.tsv（id\t文本），并打印总耗时、实时率、加载后内存增量。
/// MOTING_BENCH_MODELS：逗号分隔，可为离线模型 id，或 stream:<目录名>（评测目录 models/ 下的流式 transducer），
/// 或 stream:default（当前实时默认模型）。仅在设置了 MOTING_BENCH_DIR 时运行
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOTING_BENCH_DIR"] != nil), .timeLimit(.minutes(120)))
func meetingBenchmark() throws {
    let env = ProcessInfo.processInfo.environment
    let dir = URL(fileURLWithPath: env["MOTING_BENCH_DIR"]!)
    let ids = try String(contentsOf: dir.appendingPathComponent("refs.tsv"), encoding: .utf8)
        .split(separator: "\n").map { String($0.split(separator: "\t")[0]) }
    let clips = try ids.map { ($0, try readWav16k(dir.appendingPathComponent("wav/\($0).wav"))) }
    let audioSeconds = Double(clips.reduce(0) { $0 + $1.1.count }) / 16_000
    let store = ModelStore(root: AppPaths.default.modelsRoot)
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("out"), withIntermediateDirectories: true)

    for spec in (env["MOTING_BENCH_MODELS"] ?? "").split(separator: ",").map(String.init) {
        let before = benchRSS()
        let recognize: ([Float]) throws -> String
        let name: String
        if spec.hasPrefix("stream:") {
            let sub = String(spec.dropFirst(7))
            let r: SherpaRecognizer
            if sub == "default" {
                r = try SherpaRecognizer(model: ModelCatalog.default, directory: store.directory(for: ModelCatalog.default))
                name = "stream-\(ModelCatalog.default.id)"
            } else {
                let m = StreamingModel(id: sub, displayName: sub, repo: "", kind: .transducer, files: [],
                                       roles: ["encoder": "encoder.int8.onnx", "decoder": "decoder.onnx",
                                               "joiner": "joiner.int8.onnx", "tokens": "tokens.txt"])
                r = try SherpaRecognizer(model: m, directory: dir.appendingPathComponent("models/\(sub)"))
                name = "stream-\(sub)"
            }
            recognize = { transcribe(r, $0) }
        } else {
            let m = try #require(OfflineCatalog.model(id: spec))
            let r = try SherpaOfflineRecognizer(model: m, directory: store.directory(for: m), hotwords: [])
            let p: Punctuator? = m.hasPunctuation ? nil
                : try Punctuator(model: OfflineCatalog.punctuation, directory: store.directory(for: OfflineCatalog.punctuation))
            recognize = { s in
                let t = try r.recognize(s)
                return p?.punctuate(t) ?? t
            }
            name = spec
        }
        let loaded = benchRSS() - before
        var lines: [String] = []
        let t0 = Date()
        for (id, samples) in clips {
            lines.append("\(id)\t\(try recognize(samples).replacingOccurrences(of: "\n", with: " "))")
        }
        let cost = Date().timeIntervalSince(t0)
        try lines.joined(separator: "\n").write(to: dir.appendingPathComponent("out/\(name).tsv"), atomically: true, encoding: .utf8)
        print(String(format: "BENCH %@ 音频 %.1f 分钟 耗时 %.1f 秒 RTF %.3f 加载内存 +%d MB 峰值RSS %d MB",
                     name, audioSeconds / 60, cost, cost / audioSeconds, loaded / 1_048_576, benchPeakRSS() / 1_048_576))
    }
}

private func benchRSS() -> Int64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
    }
    return kr == KERN_SUCCESS ? Int64(info.resident_size) : 0
}

private func benchPeakRSS() -> Int64 {
    var u = rusage()
    getrusage(RUSAGE_SELF, &u)
    return Int64(u.ru_maxrss)   // macOS 上单位是字节
}

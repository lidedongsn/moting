import Darwin
import Foundation
import Testing
import MotingCapture
import MotingCore
import MotingStorage
@testable import MotingASR

/// 当前进程常驻内存（字节）
private func residentBytes() -> Int64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Int64(info.resident_size) : 0
}

/// 三个候选模型跑同一组音频，并排输出识别文字、RTF、加载后内存。仅在 MOTING_ASR_BENCH=1 时运行。
/// 音频：模型仓库自带 test_wavs/0~3.wav（中英混说），以及用户最长一场会议两路录音的前 60 秒
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOTING_ASR_BENCH"] == "1"), .timeLimit(.minutes(20)))
func compareModels() async throws {
    let paths = AppPaths.default
    let store = ModelStore(root: paths.modelsRoot)

    var clips: [(String, [Float])] = []
    for name in ["0.wav", "1.wav", "2.wav", "3.wav"] {
        let tmp = try await downloadTestWav(repo: ModelCatalog.bilingualZipformer.repo, name: name)
        defer { try? FileManager.default.removeItem(at: tmp) }
        clips.append(("示例 \(name)", try readWav16k(tmp)))
    }
    // 用户自己的录音：取 system.pcm 最大的那场会议
    let meetingsDir = paths.meetingsRoot
    let dirs = (try? FileManager.default.contentsOfDirectory(at: meetingsDir, includingPropertiesForKeys: nil)) ?? []
    if let longest = dirs.max(by: {
        ((try? PCMTrackReader.sampleCount($0.appendingPathComponent("system.pcm"))) ?? 0)
            < ((try? PCMTrackReader.sampleCount($1.appendingPathComponent("system.pcm"))) ?? 0)
    }) {
        for ch in AudioChannel.allCases {
            let url = longest.appendingPathComponent("\(ch.rawValue).pcm")
            if let s = try? PCMTrackReader.readAll(url), !s.isEmpty {
                clips.append(("你的录音·\(ch == .mic ? "我" : "对方")（前 60 秒）", Array(s.prefix(16_000 * 60))))
            }
        }
    }

    var report = "# 实时识别模型对比\n\n"
    for m in ModelCatalog.all where store.isInstalled(m) {
        let before = residentBytes()
        let r = try SherpaRecognizer(model: m, directory: store.directory(for: m))
        let mem = residentBytes() - before
        report += "## \(m.displayName)（\(m.totalSize / 1_048_576)MB，加载后内存约 +\(mem / 1_048_576)MB）\n\n"
        for (name, samples) in clips {
            let t0 = Date()
            let text = transcribe(r, samples)
            let rtf = Date().timeIntervalSince(t0) / (Double(samples.count) / 16_000)
            report += "- **\(name)**（RTF \(String(format: "%.3f", rtf))）：\(text.isEmpty ? "（空）" : text)\n"
        }
        report += "\n"
    }
    print(report)
}

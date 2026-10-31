import Foundation
import Testing
@testable import MotingDSP

/// 实测：拿一场外放录音的两路文件跑去回声，打印压低多少。
/// MOTING_AEC_DIR=会议目录 MOTING_AEC_OUT=输出 pcm 路径 swift test --filter recordedMeeting
@Test(.enabled(if: ProcessInfo.processInfo.environment["MOTING_AEC_DIR"] != nil))
func recordedMeetingEchoReduction() throws {
    let env = ProcessInfo.processInfo.environment
    let dir = URL(fileURLWithPath: env["MOTING_AEC_DIR"]!)
    func load(_ name: String) throws -> [Float] {
        try Data(contentsOf: dir.appendingPathComponent(name)).withUnsafeBytes { r in
            r.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_768 }
        }
    }
    let mic = try load("mic.pcm"), sys = try load("system.pcm")
    let n = min(mic.count, sys.count)
    let f = MicEchoFilter()
    var out: [Float] = []
    let t0 = Date()
    for p in stride(from: 0, to: n - 1_600, by: 1_600) {
        f.reference(Array(sys[p..<p + 1_600]), start: p)
        if let r = f.mic(Array(mic[p..<p + 1_600]), start: p) { out += r.samples }
    }
    if let r = f.flush() { out += r.samples }
    print(String(format: "处理 %.0f 秒音频用时 %.2f 秒（单核占用约 %.1f%%）", Double(n) / 16_000,
                 Date().timeIntervalSince(t0), Date().timeIntervalSince(t0) / (Double(n) / 16_000) * 100))
    // 每秒打印：麦克风能量、输出能量（dB）
    for s in stride(from: 0, to: min(out.count, n) - 16_000, by: 16_000) {
        let e = { (x: ArraySlice<Float>) in 10 * log10(x.reduce(0) { $0 + Double($1 * $1) } / 16_000 + 1e-12) }
        print(String(format: "%3d 秒  系统 %6.1f  麦克风 %6.1f  去回声后 %6.1f", s / 16_000,
                     e(sys[s..<s + 16_000]), e(mic[s..<s + 16_000]), e(out[s..<s + 16_000])))
    }
    if let path = env["MOTING_AEC_OUT"] {
        var d = Data(capacity: out.count * 2)
        for x in out { withUnsafeBytes(of: Int16(max(-32_768, min(32_767, x * 32_768))).littleEndian) { d.append(contentsOf: $0) } }
        try d.write(to: URL(fileURLWithPath: path))
    }
}

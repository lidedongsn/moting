import Foundation
import Testing
@testable import MotingCapture

@Test(arguments: [48_000.0, 44_100.0, 24_000.0, 16_000.0])
func resamplesCommonRates(rate: Double) throws {
    let r = try Resampler(inputSampleRate: rate)
    let total = Int(rate)
    let sine = (0..<total).map { Float(sin(2 * Double.pi * 440 * Double($0) / rate)) * 0.5 }
    let block = Int(rate / 100)
    var out: [Float] = []
    var i = 0
    while i < total {
        out += try r.process(Array(sine[i..<min(i + block, total)]))
        i += block
    }
    out += try r.flush()
    #expect(abs(out.count - 16_000) <= 32, "rate \(rate) 输出 \(out.count)")
    // 中段 0.5 秒的过零次数 ≈ 440 次（每秒 880 次）
    let mid = Array(out[4000..<12000])
    var crossings = 0
    for k in 1..<mid.count where (mid[k - 1] < 0) != (mid[k] < 0) { crossings += 1 }
    #expect(abs(Double(crossings) - 440) <= 440 * 0.02, "rate \(rate) 过零 \(crossings)")
}

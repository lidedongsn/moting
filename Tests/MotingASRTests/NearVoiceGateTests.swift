import Foundation
import Testing
@testable import MotingASR

/// 生成指定电平（dBFS，RMS）的信号：语音用 300Hz 正弦近似，噪声用伪随机
private func tone(_ db: Double, seconds: Double, freq: Double = 300) -> [Float] {
    let amp = pow(10, db / 20) * 2.squareRoot()
    return (0..<Int(seconds * 16_000)).map { Float(amp * sin(2 * .pi * freq * Double($0) / 16_000)) }
}

private func noise(_ db: Double, seconds: Double) -> [Float] {
    var x: UInt32 = 12345
    let amp = pow(10, db / 20) * 3.squareRoot()
    return (0..<Int(seconds * 16_000)).map { _ in
        x = x &* 1_664_525 &+ 1_013_904_223
        return Float(amp * (Double(x) / Double(UInt32.max) * 2 - 1))
    }
}

/// 分块喂入，返回与输入对齐的输出（去掉 lookahead 延迟）
private func run(_ gate: inout NearVoiceGate, _ input: [Float], block: Int = 320, delay: Int = 3_200) -> [Float] {
    var out: [Float] = []
    var i = 0
    while i < input.count {
        out += gate.process(Array(input[i..<min(i + block, input.count)]))
        i += block
    }
    out += gate.process([Float](repeating: 0, count: delay))
    return Array(out.dropFirst(delay))
}

private func rms(_ x: ArraySlice<Float>) -> Float {
    guard !x.isEmpty else { return 0 }
    return (x.reduce(0) { $0 + $1 * $1 } / Float(x.count)).squareRoot()
}

private func sec(_ s: Double) -> Int { Int(s * 16_000) }

@Test func nearSpeechPassesAndNoiseIsMuted() {
    var g = NearVoiceGate()
    let input = noise(-60, seconds: 2) + tone(-25, seconds: 1) + noise(-60, seconds: 2)
    let out = run(&g, input)
    #expect(rms(out[sec(2.1)..<sec(2.9)]) > 0.03)
    #expect(rms(out[sec(0.5)..<sec(1.5)]) == 0)
    #expect(rms(out[sec(3.5)..<sec(4.5)]) == 0)
}

@Test func farSpeechIsMuted() {
    var g = NearVoiceGate()
    let input = noise(-60, seconds: 1) + tone(-25, seconds: 3) + noise(-60, seconds: 1)
        + tone(-45, seconds: 2, freq: 220) + noise(-60, seconds: 1)
    let out = run(&g, input)
    #expect(rms(out[sec(1.5)..<sec(3.5)]) > 0.03)
    #expect(rms(out[sec(5.4)..<sec(6.6)]) == 0)
}

@Test func onsetIsPreserved() {
    var g = NearVoiceGate()
    let input = noise(-60, seconds: 2) + tone(-25, seconds: 1) + noise(-60, seconds: 1)
    let out = run(&g, input)
    #expect(rms(out[sec(2.0)..<sec(2.1)]) > 0.03)
}

@Test func outputLengthEqualsInput() {
    var g = NearVoiceGate()
    var total = 0
    for n in [1, 100, 320, 777, 5_000, 3] {
        total += g.process([Float](repeating: 0.01, count: n)).count
        #expect(total == [1, 100, 320, 777, 5_000, 3].prefix { $0 != n }.reduce(n, +))
    }
}

@Test func quietStartIsNotOverFiltered() {
    var g = NearVoiceGate()
    let input = noise(-60, seconds: 1) + tone(-35, seconds: 1) + noise(-60, seconds: 1)
    let out = run(&g, input)
    #expect(rms(out[sec(1.1)..<sec(1.9)]) > 0.01)
}

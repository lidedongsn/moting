import Foundation
import Testing
@testable import MotingDSP

/// 可复现的伪随机零均值噪声
private func noise(_ n: Int, seed: UInt64) -> [Float] {
    var g = seed
    return (0..<n).map { _ in
        g = g &* 6364136223846793005 &+ 1442695040888963407
        return Float(Int64(bitPattern: g >> 11) % 2000) / 1000 - 1
    }
}

/// 类语音：噪声乘以几赫兹起伏、带停顿的包络
private func speech(seconds: Double, seed: UInt64, rate: Float = 2.3) -> [Float] {
    let n = Int(seconds * 16_000)
    let x = noise(n, seed: seed)
    return (0..<n).map { i in x[i] * max(0, sin(Float(i) / 16_000 * 2 * .pi * rate)) * 0.5 }
}

private func delayed(_ x: [Float], by d: Int, gain: Float) -> [Float] {
    (0..<x.count).map { i in i >= d ? x[i - d] * gain : 0 }
}

private func add(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map(+) }

private let seconds = 60.0
private let system = speech(seconds: seconds, seed: 3)
/// 扬声器漏进麦克风：晚 60ms、衰减到 0.3，加一点底噪
private let bleed = add(delayed(system, by: 960, gain: 0.3), noise(system.count, seed: 9).map { $0 * 0.002 })

@Test func estimatesDelayAndGainOfSpeakerBleed() throws {
    let model = try #require(EnergyEcho.estimate(mic: EnergyEcho.frameEnergies(bleed), system: EnergyEcho.frameEnergies(system)))
    #expect(model.lag == 3)   // 60ms = 3 帧
    #expect(abs(model.gain - 0.09) < 0.03)   // 能量比 = 0.3²
}

@Test func noModelWhenMicDoesNotFollowSystem() {
    // 戴耳机：麦克风里只有自己说话，跟对方声音无关
    let mine = speech(seconds: seconds, seed: 11, rate: 1.7)
    #expect(EnergyEcho.estimate(mic: EnergyEcho.frameEnergies(mine), system: EnergyEcho.frameEnergies(system)) == nil)
}

@Test func classifiesBleedOnlySegmentAsEcho() throws {
    let mic = EnergyEcho.frameEnergies(bleed), sys = EnergyEcho.frameEnergies(system)
    let model = try #require(EnergyEcho.estimate(mic: mic, system: sys))
    #expect(EnergyEcho.isBleed(start: 10, end: 14, mic: mic, system: sys, model: model))
}

@Test func keepsLocalSpeechEvenDuringDoubleTalk() throws {
    // 20–30 秒自己也在说，比漏进来的声音响
    var mine = [Float](repeating: 0, count: system.count)
    let talk = speech(seconds: 10, seed: 21, rate: 3.1)
    for i in 0..<talk.count { mine[20 * 16_000 + i] = talk[i] * 0.8 }
    let micSamples = add(bleed, mine)
    let mic = EnergyEcho.frameEnergies(micSamples), sys = EnergyEcho.frameEnergies(system)
    let model = try #require(EnergyEcho.estimate(mic: mic, system: sys))
    #expect(!EnergyEcho.isBleed(start: 21, end: 29, mic: mic, system: sys, model: model))
    #expect(EnergyEcho.isBleed(start: 40, end: 44, mic: mic, system: sys, model: model))
}

@Test func silentSegmentIsNotJudged() throws {
    let mic = EnergyEcho.frameEnergies(bleed), sys = EnergyEcho.frameEnergies(system)
    let model = try #require(EnergyEcho.estimate(mic: mic, system: sys))
    // 超出录音范围：没有可判断的帧，保留
    #expect(!EnergyEcho.isBleed(start: 100, end: 104, mic: mic, system: sys, model: model))
}

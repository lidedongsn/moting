import Foundation
import Testing
@testable import MotingDSP

/// 类语音的远端信号：随机噪声乘以几赫兹起伏的包络（有停顿），可复现
private func farEnd(seconds: Double, seed: UInt64 = 7) -> [Float] {
    var g = seed
    let n = Int(seconds * 16_000)
    return (0..<n).map { i in
        g = g &* 6364136223846793005 &+ 1442695040888963407
        let noise = Float(Int64(bitPattern: g >> 11) % 2000) / 1000 - 1   // 零均值
        let env = max(0, sin(Float(i) / 16_000 * 2 * .pi * 2.3)) * 0.6 + 0.05
        return noise * env * 0.5
    }
}

/// 把 x 平移 delay 个采样（正数：延后）并缩放，模拟扬声器到麦克风的回声
private func echo(of x: [Float], delay: Int, gain: Float) -> [Float] {
    (0..<x.count).map { i in
        let j = i - delay
        return j >= 0 && j < x.count ? x[j] * gain : 0
    }
}

private func energy(_ x: ArraySlice<Float>) -> Double {
    x.reduce(0) { $0 + Double($1 * $1) } / Double(max(1, x.count))
}

/// 按 0.1 秒一块交替送入参考和麦克风，收集输出
private func run(mic: [Float], ref: [Float]?, chunk: Int = 1_600) -> [Float] {
    let f = MicEchoFilter()
    var out: [Float] = []
    var pos = 0
    while pos < mic.count {
        let end = min(pos + chunk, mic.count)
        if let ref { f.reference(Array(ref[pos..<end]), start: pos) }
        if let r = f.mic(Array(mic[pos..<end]), start: pos) {
            #expect(r.start == out.count, "输出要连续")
            out += r.samples
        }
        pos = end
    }
    if let r = f.flush() { out += r.samples }
    return out
}

@Test func echoIsCancelledAfterConvergence() {
    let ref = farEnd(seconds: 8)
    let mic = echo(of: ref, delay: 480, gain: 0.5)         // 回声晚 30ms 到达麦克风
    let out = run(mic: mic, ref: ref)
    #expect(out.count == mic.count)
    let tail = (mic.count - 3 * 16_000)..<mic.count
    let reductionDB = 10 * log10(energy(mic[tail]) / max(energy(out[tail]), 1e-12))
    #expect(reductionDB > 15, "回声只压低了 \(reductionDB) dB")
}

@Test func echoArrivingSlightlyBeforeReferenceIsStillCancelled() {
    // 两路时间轴有偏差时，回声可能比参考早几十毫秒出现在麦克风里
    let ref = farEnd(seconds: 8, seed: 11)
    let mic = echo(of: ref, delay: -800, gain: 0.5)        // 早 50ms
    let out = run(mic: mic, ref: ref)
    let tail = (mic.count - 3 * 16_000)..<mic.count
    let reductionDB = 10 * log10(energy(mic[tail]) / max(energy(out[tail]), 1e-12))
    #expect(reductionDB > 15, "回声只压低了 \(reductionDB) dB")
}

@Test func nearEndSpeechPassesWhenNothingIsPlaying() {
    let near = farEnd(seconds: 4, seed: 3)
    let silentRef = [Float](repeating: 0, count: near.count)
    let out = run(mic: near, ref: silentRef)
    let mid = 16_000..<(near.count - 1)
    let changeDB = 10 * log10(energy(near[mid]) / max(energy(out[mid]), 1e-12))
    #expect(abs(changeDB) < 3, "没有外放时自己的声音被改变了 \(changeDB) dB")
}

@Test func micKeepsFlowingWhenReferenceNeverArrives() {
    // 系统音频一路断了：麦克风不能一直等参考，最多晚 maxWait 就照常输出
    let near = farEnd(seconds: 2, seed: 5)
    let out = run(mic: near, ref: nil)
    #expect(out.count == near.count)
}

@Test func ownVoiceSurvivesWhileSpeakerIsPlaying() {
    // 先只有外放（滤波器学到回声路径），4 秒后自己也开始说话：去掉回声后剩下的应接近自己的声音
    let ref = farEnd(seconds: 8, seed: 21)
    let near = farEnd(seconds: 8, seed: 99).enumerated().map { $0.offset < 4 * 16_000 ? 0 : $0.element * 0.5 }
    let e = echo(of: ref, delay: 480, gain: 0.5)
    let mic = zip(near, e).map { $0 + $1 }
    let out = run(mic: mic, ref: ref)
    let tail = (mic.count - 3 * 16_000)..<mic.count
    let residual = zip(out[tail], near[tail]).map { $0 - $1 }
    let echoToNearDB = 10 * log10(energy(e[tail]) / max(energy(residual[...]), 1e-12))
    #expect(echoToNearDB > 6, "去回声后与自己声音的偏差只比原回声小 \(echoToNearDB) dB")
}

@Test func micPassesThroughImmediatelyBeforeAnyReference() {
    // 系统音频一路还没有数据（没开或还没起来）：不等，原样立即输出
    let f = MicEchoFilter()
    let x = farEnd(seconds: 0.1, seed: 1)
    let r = f.mic(x, start: 0)
    #expect(r?.start == 0)
    #expect(r?.samples.count == x.count && r?.samples.first == x.first)
    let r2 = f.mic(x, start: 1_600)
    #expect(r2?.start == 1_600)
}

@Test func distortedSpeakerEchoIsSuppressed() {
    // 笔记本扬声器有失真、房间有底噪：线性滤波消不干净，剩下的残余回声仍会被识别成字，要压到听不见
    let ref = farEnd(seconds: 8, seed: 31)
    let noise = farEnd(seconds: 8, seed: 77).map { $0 * 0.003 }
    let mic = zip(echo(of: ref, delay: 480, gain: 0.5), noise).map { tanh($0 * 10) / 10 + $1 }
    let out = run(mic: mic, ref: ref)
    let tail = (mic.count - 3 * 16_000)..<mic.count
    let reductionDB = 10 * log10(energy(mic[tail]) / max(energy(out[tail]), 1e-12))
    #expect(reductionDB > 25, "回声只压低了 \(reductionDB) dB")
}

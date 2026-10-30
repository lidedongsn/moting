import Testing
import MotingCapture
@testable import MotingRecording

private func chunk(_ level: Float) -> AudioSourceEvent {
    .chunk(AudioChunk(samples: [0.1], level: level))
}

@Test func okWhenSoundArrives() {
    var h = ChannelHealth()
    h.record(chunk(0.05), at: 1)
    #expect(h.status(at: 2) == .ok)
}

@Test func silentAfterTenSecondsOfExactZero() {
    // 没有系统音频权限时 Tap 照样送数据，但全是 0
    var h = ChannelHealth()
    for t in stride(from: 0.5, through: 10.5, by: 0.5) { h.record(chunk(0), at: t) }
    #expect(h.status(at: 9) == .ok)
    #expect(h.status(at: 10.5) == .silent)
}

@Test func soundOnceClearsSilentForever() {
    var h = ChannelHealth()
    h.record(chunk(0.02), at: 1)
    for t in stride(from: 2.0, through: 30, by: 1) { h.record(chunk(0), at: t) }
    #expect(h.status(at: 30) == .ok)
}

@Test func interruptedUntilResumed() {
    var h = ChannelHealth()
    h.record(chunk(0.05), at: 1)
    h.record(.interrupted("默认输入设备已变化"), at: 2)
    #expect(h.status(at: 3) == .interrupted("默认输入设备已变化"))
    h.record(.resumed, at: 4)
    h.record(chunk(0.05), at: 4.1)
    #expect(h.status(at: 4.2) == .ok)
}

@Test func stalledWhenNoDataForThreeSeconds() {
    var h = ChannelHealth()
    h.record(chunk(0.05), at: 1)
    #expect(h.status(at: 3.5) == .ok)
    #expect(h.status(at: 4.5) == .stalled)
}

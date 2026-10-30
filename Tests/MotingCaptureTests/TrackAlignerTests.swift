import Testing
@testable import MotingCapture

@Test func noPaddingWithinTolerance() {
    #expect(TrackAligner().adjustment(expectedElapsed: 1.1, written: 16_000, incoming: 1_600) == 0)
}

@Test func padsWhenBehind() {
    #expect(TrackAligner().adjustment(expectedElapsed: 2.0, written: 0, incoming: 1_600) == 30_400)
}

@Test func smallLeadIsKept() {
    // 超前 100ms，在容差内不动
    #expect(TrackAligner().adjustment(expectedElapsed: 1.0, written: 16_000, incoming: 1_600) == 0)
}

@Test func dropsWhenAheadBeyondTolerance() {
    // 应写到 1s，已写 1s，再来 0.5s → 超前 0.5s，丢弃 8000
    #expect(TrackAligner().adjustment(expectedElapsed: 1.0, written: 16_000, incoming: 8_000) == -8_000)
}

@Test func dropNeverExceedsIncoming() {
    #expect(TrackAligner().adjustment(expectedElapsed: 1.0, written: 100_000, incoming: 1_600) == -1_600)
}

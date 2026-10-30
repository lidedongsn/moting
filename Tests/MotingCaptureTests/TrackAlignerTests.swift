import Testing
@testable import MotingCapture

@Test func noPaddingWithinTolerance() {
    #expect(TrackAligner().silenceToInsert(expectedElapsed: 1.1, written: 16_000, incoming: 1_600) == 0)
}

@Test func padsWhenBehind() {
    #expect(TrackAligner().silenceToInsert(expectedElapsed: 2.0, written: 0, incoming: 1_600) == 30_400)
}

@Test func neverNegative() {
    #expect(TrackAligner().silenceToInsert(expectedElapsed: 1.0, written: 100_000, incoming: 1_600) == 0)
}

import Foundation
import Testing
import MotingCore
@testable import MotingASR

private let block = [Float](repeating: 0, count: 1_600)

/// 脚本顺序：第一个 makeStream 给 mic，第二个给 system
private func make(_ mic: [FakeRecognizer.Step], _ system: [FakeRecognizer.Step] = []) -> (LiveTranscriber, EventLog) {
    let log = EventLog()
    let t = LiveTranscriber(recognizer: FakeRecognizer([mic, system]), versionID: UUID()) { log.add($0) }
    return (t, log)
}

@Test func partialThenFinalWithMeetingTimes() {
    let (t, log) = make([.init(text: "你"), .init(text: "你好"), .init(text: "你好", endpoint: true)])
    t.feed(.mic, block, startSample: 0)
    t.feed(.mic, block, startSample: 1_600)
    t.feed(.mic, block, startSample: 3_200)
    t.waitUntilIdle()
    #expect(log.partialTexts == ["你", "你好"])
    let f = try! #require(log.finals.first)
    #expect(log.finals.count == 1)
    #expect(f.text == "你好")
    #expect(f.channel == .mic)
    #expect(f.start == 0)
    #expect(abs(f.end - 0.3) < 1e-9)
}

@Test func emptyEndpointProducesNoSegment() {
    let (t, log) = make([.init(text: ""), .init(text: "", endpoint: true), .init(text: "")])
    for i in 0..<3 { t.feed(.mic, block, startSample: i * 1_600) }
    t.waitUntilIdle()
    #expect(log.all.isEmpty)
}

@Test func channelsAreIndependent() {
    let (t, log) = make([.init(text: "我说", endpoint: true)],
                        [.init(text: "你"), .init(text: "你说", endpoint: true)])
    t.feed(.mic, block, startSample: 16_000)
    t.feed(.system, block, startSample: 0)
    t.feed(.system, block, startSample: 1_600)
    t.waitUntilIdle()
    let mic = log.finals.first { $0.channel == .mic }
    let sys = log.finals.first { $0.channel == .system }
    #expect(mic?.text == "我说")
    #expect(mic?.start == 1.0)
    #expect(sys?.text == "你说")
    #expect(sys?.start == 0)
    #expect(abs((sys?.end ?? 0) - 0.2) < 1e-9)
}

@Test func secondSentenceStartsAfterEndpoint() {
    let (t, log) = make([.init(text: "一", endpoint: true), .init(text: "二"), .init(text: "二", endpoint: true)])
    for i in 0..<3 { t.feed(.mic, block, startSample: i * 1_600) }
    t.waitUntilIdle()
    #expect(log.finals.map(\.text) == ["一", "二"])
    #expect(log.finals.last?.start == 0.1)
}

@Test func finishFlushesPartial() {
    let (t, log) = make([.init(text: "还没说完")])
    t.feed(.mic, block, startSample: 0)
    t.finish()
    t.waitUntilIdle()
    #expect(log.finals.map(\.text) == ["还没说完"])
}

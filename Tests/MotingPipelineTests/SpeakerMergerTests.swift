import Foundation
import Testing
import MotingASR
@testable import MotingPipeline

private func turn(_ s: Double, _ e: Double, _ who: Int) -> SpeakerTurn {
    SpeakerTurn(start: s, end: e, speaker: who)
}

private func speakers(_ turns: [SpeakerTurn]) -> Set<Int> { Set(turns.map(\.speaker)) }

@Test func sameVoiceSplitIntoClustersIsMerged() {
    // 实测：同一个人被切开时，整体声纹相似度 0.82–0.92
    let turns = [turn(0, 30, 1), turn(31, 40, 2), turn(41, 45, 3)]
    let r = SpeakerMerger.merge(turns, embeddings: [1: [1, 0], 2: [0.9, 0.2], 3: [0.95, 0.1]])
    #expect(speakers(r).count == 1)
    #expect(r.count == 3, "只改归属，不改时间")
    #expect(r.map(\.start) == [0, 31, 41])
}

@Test func differentPeopleStaySeparate() {
    // 实测：不同的人相似度最高 0.52
    let turns = [turn(0, 10, 1), turn(11, 20, 2)]
    let r = SpeakerMerger.merge(turns, embeddings: [1: [1, 0], 2: [0.5, 0.866]])
    #expect(speakers(r).count == 2)
}

@Test func tooShortClusterJoinsTheNearestSpeakerInTime() {
    // 不到 3 秒的声纹不可信，即使相似度低也不算一个人
    let turns = [turn(0, 10, 1), turn(20, 21, 9), turn(22, 32, 2)]
    let r = SpeakerMerger.merge(turns, embeddings: [1: [1, 0], 2: [0, 1], 9: [0.7, 0.7]])
    #expect(r.first { $0.start == 20 }?.speaker == 2)
    #expect(speakers(r) == [1, 2])
}

@Test func whenEveryClusterIsTooShortTheyBecomeOneSpeaker() {
    let turns = [turn(0, 1, 1), turn(2, 3, 2)]
    #expect(speakers(SpeakerMerger.merge(turns, embeddings: [:])).count == 1)
}

@Test func mergingUsesTheAverageVoiceSoItDoesNotChainThroughASimilarNeighbor() {
    // A 像 B、B 像 C，但 A 和 C 明显不同：不能因为串联就并成一个人
    let a: [Float] = [1, 0], b: [Float] = [0.75, 0.66], c: [Float] = [0, 1]
    let turns = [turn(0, 30, 1), turn(31, 60, 2), turn(61, 90, 3)]
    #expect(speakers(SpeakerMerger.merge(turns, embeddings: [1: a, 2: b, 3: c])).count >= 2)
}

@Test func missingEmbeddingKeepsClusterSeparateWhenLongEnough() {
    let turns = [turn(0, 10, 1), turn(11, 20, 2)]
    #expect(speakers(SpeakerMerger.merge(turns, embeddings: [1: [1, 0]])).count == 2)
}

@Test func emptyInput() {
    #expect(SpeakerMerger.merge([], embeddings: [:]).isEmpty)
}

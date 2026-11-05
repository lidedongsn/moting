import Foundation
import Testing
@testable import MotingCore

private let version = UUID()
private func seg(_ ch: AudioChannel, _ label: String?, _ start: Double, _ end: Double, _ text: String = "x") -> TranscriptSegment {
    TranscriptSegment(versionID: version, channel: ch, speakerLabel: label, start: start, end: end, text: text)
}

@Test func consecutiveSentencesBySameSpeakerBecomeOneTurn() {
    let turns = TranscriptTurns.group([seg(.mic, nil, 0, 2), seg(.mic, nil, 2.5, 4), seg(.system, "说话人 1", 5, 7)])
    #expect(turns.map(\.segments.count) == [2, 1])
    #expect(turns[0].speaker == .me)
    #expect(turns[1].speaker == .other("说话人 1"))
    #expect(turns[0].start == 0 && turns[0].end == 4)
}

@Test func longSilenceStartsANewTurn() {
    let turns = TranscriptTurns.group([seg(.mic, nil, 0, 2), seg(.mic, nil, 2 + TranscriptTurns.maxGap + 1, 40)])
    #expect(turns.count == 2)
}

@Test func longMonologueIsSplitSoClickingStillJumpsNearby() {
    let segments = stride(from: 0.0, to: 200, by: 10).map { seg(.mic, nil, $0, $0 + 9) }
    let turns = TranscriptTurns.group(segments)
    #expect(turns.count > 1)
    #expect(turns.allSatisfy { $0.end - $0.start <= TranscriptTurns.maxLength + 10 })
    #expect(turns.flatMap(\.segments).count == segments.count)
}

@Test func emptyTranscriptHasNoTurns() {
    #expect(TranscriptTurns.group([]).isEmpty)
}

@Test func unsortedInputIsOrderedByTime() {
    let turns = TranscriptTurns.group([seg(.system, "说话人 1", 5, 7), seg(.mic, nil, 0, 2)])
    #expect(turns.first?.speaker == .me)
}

@Test func findsTheTurnBeingPlayed() {
    let turns = TranscriptTurns.group([seg(.mic, nil, 0, 2), seg(.system, "说话人 1", 5, 7), seg(.mic, nil, 10, 12)])
    #expect(TranscriptTurns.index(in: turns, at: -1) == nil)
    #expect(TranscriptTurns.index(in: turns, at: 0) == 0)
    #expect(TranscriptTurns.index(in: turns, at: 6) == 1)
    #expect(TranscriptTurns.index(in: turns, at: 100) == 2)
}

// MARK: - 一段发言里点到哪句

@Test func chineseSentencesJoinWithoutSpaces() {
    let turn = TranscriptTurns.group([seg(.mic, nil, 0, 1, "你好。"), seg(.mic, nil, 1, 2, "再见。")])[0]
    #expect(TurnText(turn).text == "你好。再见。")
}

@Test func englishSentencesGetASpaceBetween() {
    let turn = TranscriptTurns.group([seg(.mic, nil, 0, 1, "Hello."), seg(.mic, nil, 1, 2, "Bye.")])[0]
    #expect(TurnText(turn).text == "Hello. Bye.")
}

@Test func characterPositionFindsItsSentence() throws {
    let turn = TranscriptTurns.group([seg(.mic, nil, 0, 1, "你好。"), seg(.mic, nil, 3, 4, "再见。")])[0]
    let t = TurnText(turn)
    #expect(t.segment(atCharacter: 0)?.start == 0)
    #expect(t.segment(atCharacter: 2)?.start == 0)
    #expect(t.segment(atCharacter: 3)?.start == 3)
    #expect(t.segment(atCharacter: 5)?.start == 3)
    #expect(t.segment(atCharacter: 6) == nil)
    #expect(t.segment(atCharacter: -1) == nil)
}

@Test func spaceBetweenSentencesBelongsToThePreviousOne() {
    let turn = TranscriptTurns.group([seg(.mic, nil, 0, 1, "Hi."), seg(.mic, nil, 3, 4, "Bye.")])[0]
    #expect(TurnText(turn).segment(atCharacter: 3)?.start == 0)   // "Hi. " 的空格
    #expect(TurnText(turn).segment(atCharacter: 4)?.start == 3)
}

@Test func rangesAreInUTF16SoEmojiDoNotShiftThem() {
    let turn = TranscriptTurns.group([seg(.mic, nil, 0, 1, "😀好。"), seg(.mic, nil, 3, 4, "再见。")])[0]
    let t = TurnText(turn)
    #expect(t.ranges[1].range.location == ("😀好。" as NSString).length)
    #expect(t.segment(atCharacter: 4)?.start == 3)
}

@Test func playbackLeadDependsOnTranscriptKind() {
    let s = seg(.mic, nil, 10, 12)
    // 精准稿时间准，只留一点余量；实时草稿句首偏晚，多提前一些
    #expect(TranscriptTurns.playbackStart(of: s, kind: .final) == 9.8)
    #expect(TranscriptTurns.playbackStart(of: s, kind: .draft) == 9)
    #expect(TranscriptTurns.playbackStart(of: seg(.mic, nil, 0.1, 1), kind: .final) == 0)
}

// MARK: - 编辑后把文字对回各句

private func twoSentences() -> [TranscriptSegment] {
    [seg(.mic, nil, 0, 1, "第一句。"), seg(.mic, nil, 2, 3, "第二句。")]
}

@Test func unchangedTextProducesNoChanges() {
    let s = twoSentences()
    let r = TurnEdit.changes(original: s, runs: [(s[0].id, "第一句。"), (s[1].id, "第二句。")])
    #expect(r.texts.isEmpty && r.removed.isEmpty)
}

@Test func editedSentenceKeepsItsOwnIdentity() {
    let s = twoSentences()
    let r = TurnEdit.changes(original: s, runs: [(s[0].id, "第一句。"), (s[1].id, "改过的第二句。")])
    #expect(r.texts == [s[1].id: "改过的第二句。"])
    #expect(r.removed.isEmpty)
}

@Test func runsOfTheSameSentenceAreJoined() {
    // 在句子中间打字可能把一句拆成几段带相同标记的文字
    let s = twoSentences()
    let r = TurnEdit.changes(original: s, runs: [(s[0].id, "第一"), (s[0].id, "新"), (s[0].id, "句。"), (s[1].id, "第二句。")])
    #expect(r.texts == [s[0].id: "第一新句。"])
}

@Test func deletedSentenceIsRemoved() {
    let s = twoSentences()
    let r = TurnEdit.changes(original: s, runs: [(s[1].id, "第二句。")])
    #expect(r.removed == [s[0].id])
    #expect(r.texts.isEmpty)
}

@Test func blankSentenceCountsAsDeleted() {
    let s = twoSentences()
    let r = TurnEdit.changes(original: s, runs: [(s[0].id, "  \n"), (s[1].id, "第二句。")])
    #expect(r.removed == [s[0].id])
}

@Test func untaggedTextJoinsThePreviousSentence() {
    let s = twoSentences()
    let r = TurnEdit.changes(original: s, runs: [(s[0].id, "第一句。"), (nil, "补充。"), (s[1].id, "第二句。")])
    #expect(r.texts == [s[0].id: "第一句。补充。"])
}

@Test func untaggedTextAtTheVeryStartJoinsTheFirstSentence() {
    let s = twoSentences()
    let r = TurnEdit.changes(original: s, runs: [(nil, "开头。"), (s[0].id, "第一句。"), (s[1].id, "第二句。")])
    #expect(r.texts == [s[0].id: "开头。第一句。"])
}

@Test func spaceBetweenEnglishSentencesIsNotAnEdit() {
    let a = seg(.mic, nil, 0, 1, "Hello."), b = seg(.mic, nil, 2, 3, "Bye.")
    let r = TurnEdit.changes(original: [a, b], runs: [(a.id, "Hello. "), (b.id, "Bye.")])
    #expect(r.texts.isEmpty && r.removed.isEmpty)
}

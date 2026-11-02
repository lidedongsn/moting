import Testing
@testable import MotingCore

private let tencent = "com.tencent.meeting"
private let chrome = "com.google.Chrome.helper"
private let meetingApp = CallCatalog.app(forBundleID: tencent)!
private let browser = CallCatalog.app(forBundleID: chrome)!

/// 从 from 到 to 每秒观察一次
private func run(_ w: inout CallWatch, _ ids: Set<String>, recording: Bool = false, from: Int, to: Int) {
    for t in from...to { w.observe(bundleIDs: ids, recording: recording, at: Double(t)) }
}

@Test func catalogMatchesCallAppsAndHelpers() {
    #expect(CallCatalog.app(forBundleID: "com.tencent.meeting")?.name == "腾讯会议")
    #expect(CallCatalog.app(forBundleID: "com.electron.lark.helper")?.name == "飞书")
    #expect(CallCatalog.app(forBundleID: "us.zoom.xos")?.name == "Zoom")
    #expect(CallCatalog.app(forBundleID: "com.google.Chrome.helper")?.isBrowser == true)
    #expect(CallCatalog.app(forBundleID: "com.apple.VoiceMemos") == nil)
}

@Test func knownCallAppIsOfferedAfterHoldingMicTwoSeconds() {
    var w = CallWatch()
    run(&w, [tencent], from: 0, to: 1)
    #expect(w.prompt == nil)
    w.observe(bundleIDs: [tencent], recording: false, at: 2)
    #expect(w.prompt == .offer(meetingApp))
}

@Test func browserMustHoldMicTwentySeconds() {
    var w = CallWatch()
    run(&w, [chrome], from: 0, to: 19)
    #expect(w.prompt == nil)
    w.observe(bundleIDs: [chrome], recording: false, at: 20)
    #expect(w.prompt == .offer(browser))
}

@Test func unknownAppsAreIgnored() {
    var w = CallWatch()
    run(&w, ["com.apple.VoiceMemos"], from: 0, to: 60)
    #expect(w.prompt == nil)
}

@Test func noOfferWhileRecording() {
    var w = CallWatch()
    run(&w, [tencent], recording: true, from: 0, to: 10)
    #expect(w.prompt == nil)
}

@Test func offerWithdrawnWhenRecordingStartsOrCallLeaves() {
    var w = CallWatch()
    run(&w, [tencent], from: 0, to: 3)
    w.observe(bundleIDs: [tencent], recording: true, at: 4)
    #expect(w.prompt == nil)

    var v = CallWatch()
    run(&v, [tencent], from: 0, to: 3)
    run(&v, [], from: 4, to: 8)
    #expect(v.prompt == nil)
}

@Test func briefMicDropKeepsHoldTime() {
    var w = CallWatch()
    w.observe(bundleIDs: [tencent], recording: false, at: 0)
    w.observe(bundleIDs: [], recording: false, at: 1)
    w.observe(bundleIDs: [tencent], recording: false, at: 2)
    #expect(w.prompt == .offer(meetingApp))
}

@Test func dismissedCallIsNotOfferedAgainUntilOffMicForAMinute() {
    var w = CallWatch()
    run(&w, [tencent], from: 0, to: 2)
    w.dismiss()
    #expect(w.prompt == nil)
    run(&w, [tencent], from: 3, to: 30)
    #expect(w.prompt == nil)
    // 离开麦克风不到一分钟又回来：还是同一场通话
    run(&w, [], from: 31, to: 60)
    run(&w, [tencent], from: 61, to: 70)
    #expect(w.prompt == nil)
    // 离开超过一分钟：新的通话
    run(&w, [], from: 71, to: 140)
    run(&w, [tencent], from: 141, to: 143)
    #expect(w.prompt == .offer(meetingApp))
}

@Test func endedPromptWhenCallAppLeavesDuringRecording() {
    var w = CallWatch()
    run(&w, [tencent], recording: true, from: 0, to: 30)
    run(&w, [], recording: true, from: 31, to: 33)
    #expect(w.prompt == nil)
    w.observe(bundleIDs: [], recording: true, at: 35)
    #expect(w.prompt == .ended(meetingApp))
    // 又回到通话：收回提示
    w.observe(bundleIDs: [tencent], recording: true, at: 36)
    #expect(w.prompt == nil)
}

@Test func keepRecordingSilencesEndedPromptForThisRecording() {
    var w = CallWatch()
    run(&w, [tencent], recording: true, from: 0, to: 10)
    run(&w, [], recording: true, from: 11, to: 15)
    #expect(w.prompt == .ended(meetingApp))
    w.dismiss()
    run(&w, [], recording: true, from: 16, to: 30)
    #expect(w.prompt == nil)
}

@Test func recordedCallIsNotOfferedAgainAfterStop() {
    var w = CallWatch()
    run(&w, [tencent], recording: true, from: 0, to: 10)
    // 停止录音时通话还在：同一场通话不再提示
    run(&w, [tencent], recording: false, from: 11, to: 20)
    #expect(w.prompt == nil)
}

@Test func endedPromptGoesAwayWhenRecordingStops() {
    var w = CallWatch()
    run(&w, [tencent], recording: true, from: 0, to: 10)
    run(&w, [], recording: true, from: 11, to: 15)
    #expect(w.prompt == .ended(meetingApp))
    w.observe(bundleIDs: [], recording: false, at: 16)
    #expect(w.prompt == nil)
}

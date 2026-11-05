import Testing
@testable import MotingCore

@Test func newUserSeesOnboarding() {
    #expect(Onboarding.shouldShow(completed: false, hasMeetings: false))
}

@Test func finishedOnboardingIsNotShownAgain() {
    #expect(!Onboarding.shouldShow(completed: true, hasMeetings: false))
}

@Test func existingUserWithMeetingsSkipsOnboarding() {
    // 升级上来的老用户已经在用了，不要拦着他们走一遍
    #expect(!Onboarding.shouldShow(completed: false, hasMeetings: true))
}

@Test func overallProgressWeighsBySize() {
    // 一个大模型下载到一半，比小模型完成更能代表总进度
    let items: [Onboarding.Item] = [.init(size: 900, fraction: 0.5), .init(size: 100, fraction: 1)]
    #expect(Onboarding.overallProgress(items) == 0.55)
}

@Test func overallProgressHandlesEmptyAndZeroSize() {
    #expect(Onboarding.overallProgress([]) == 1)
    #expect(Onboarding.overallProgress([.init(size: 0, fraction: 0)]) == 1)
}

@Test func progressIsClampedToValidRange() {
    #expect(Onboarding.overallProgress([.init(size: 10, fraction: 1.5)]) == 1)
    #expect(Onboarding.overallProgress([.init(size: 10, fraction: -1)]) == 0)
}

// MARK: - 用电池时要不要处理

@Test func onBatteryProcessesImmediatelyByDefault() {
    // X-ASR 转写 1 小时会议只要约 1.6 分钟，没必要让用户等插电
    #expect(BatteryPolicy.processNow(stored: nil, userInitiated: false))
    #expect(BatteryPolicy.processNow(stored: "now", userInitiated: false))
}

@Test func waitingForPowerIsOnlyWhenTheUserChoseIt() {
    #expect(!BatteryPolicy.processNow(stored: "wait", userInitiated: false))
}

@Test func userClickingTranscribeNeverWaits() {
    #expect(BatteryPolicy.processNow(stored: "wait", userInitiated: true))
}

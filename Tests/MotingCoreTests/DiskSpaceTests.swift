import Foundation
import Testing
@testable import MotingCore

private let gb: Int64 = 1_000_000_000

@Test func plentyOfSpaceIsNotWorthMentioning() {
    #expect(DiskSpace.level(free: 50 * gb) == .ok)
    #expect(DiskSpace.level(free: DiskSpace.lowThreshold) == .ok)
}

@Test func belowTwoGigabytesIsLow() {
    #expect(DiskSpace.level(free: DiskSpace.lowThreshold - 1) == .low)
    #expect(DiskSpace.level(free: DiskSpace.criticalThreshold) == .low)
}

@Test func belowHalfAGigabyteIsCritical() {
    #expect(DiskSpace.level(free: DiskSpace.criticalThreshold - 1) == .critical)
    #expect(DiskSpace.level(free: 0) == .critical)
}

@Test func unknownFreeSpaceDoesNotRaiseAFalseAlarm() {
    #expect(DiskSpace.level(free: nil) == .ok)
}

@Test func estimatesRecordingTimeFromTwoUncompressedTracks() {
    // 16kHz、16 位、两路：每小时 230.4MB
    #expect(DiskSpace.bytesPerHour == 230_400_000)
    #expect(DiskSpace.recordableHours(free: 460_800_000) == 2)
    #expect(DiskSpace.recordableHours(free: 0) == 0)
}

private func notifications(_ levels: [DiskSpace.Level]) -> [Bool] {
    var alert = DiskSpace.CriticalAlert()
    return levels.map { alert.shouldNotify(level: $0) }
}

@Test func warnsOnlyWhenCrossingIntoCriticalNotEveryCheck() {
    #expect(notifications([.ok, .low, .critical, .critical]) == [false, false, true, false], "同一场只提醒一次")
}

@Test func recoveringSpaceAllowsAnotherAlertLater() {
    #expect(notifications([.critical, .ok, .critical]) == [true, false, true])
}

@Test func freeSpaceIsReadableEvenBeforeTheDataFolderExists() {
    let missing = URL(fileURLWithPath: "/tmp/moting-does-not-exist/a/b")
    #expect((DiskSpace.freeBytes(at: missing) ?? 0) > 0)
}

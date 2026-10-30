import Foundation
import MotingCapture
import MotingCore
import MotingStorage

public enum RecordingRecovery {
    /// app 启动时调用：把仍处于"录音中"的会议（上次崩溃或被强退）收尾。
    /// 修复 PCM 文件、关闭未结束的暂停、状态改为 .interrupted。
    /// 崩溃时刻未知，未结束的暂停按零时长关闭；endedAt = 开始 + 最长一路时长 + 已结束暂停总时长
    @discardableResult
    public static func run(repository: MeetingRepository, paths: AppPaths, now: Date) throws -> [UUID] {
        var recovered: [UUID] = []
        for m in try repository.meetings(status: .recording) {
            var longest = 0
            for ch in AudioChannel.allCases {
                let url = paths.trackURL(m.id, ch)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                try PCMTrackReader.repair(url)
                longest = max(longest, try PCMTrackReader.sampleCount(url))
            }
            var paused: TimeInterval = 0
            for p in try repository.pauses(m.id) {
                if let end = p.end {
                    paused += end.timeIntervalSince(p.start)
                } else {
                    try repository.endOpenPause(meetingID: m.id, at: p.start)
                }
            }
            let endedAt = m.startedAt + Double(longest) / 16_000 + paused
            try repository.setStatus(m.id, .interrupted, endedAt: min(endedAt, now))
            recovered.append(m.id)
        }
        return recovered
    }
}

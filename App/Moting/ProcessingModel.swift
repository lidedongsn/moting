import AppKit
import Foundation
import MotingCore
import MotingPipeline
import MotingStorage

/// 会后处理在界面上的状态：进度、等待插电、失败重试、完成通知；以及主窗口当前选中的会议
@MainActor
final class ProcessingModel: ObservableObject {
    /// 会议 id → 当前进度（0–1），只包含进行中的任务
    @Published private(set) var progress: [UUID: Double] = [:]
    /// 最近一次结束录音的会议（悬浮窗显示它的处理状态）
    @Published private(set) var lastRecordedMeetingID: UUID?
    /// 上面这场会议的处理状态
    @Published private(set) var lastStatus: JobStatus?
    /// 主窗口选中的会议（通知点击后跳转）
    @Published var selectedMeetingID: UUID?

    static let autoTranscribeKey = "pipeline.autoTranscribe"
    /// "wait"：用电池时等插电；"now"：立即处理
    static let batteryPolicyKey = "pipeline.batteryPolicy"

    private let env: AppEnvironment?
    private let notifier = Notifier()
    private var powerMonitor: PowerMonitor?

    init(env: AppEnvironment?) {
        self.env = env
        guard let env else { return }
        notifier.requestAuthorization()
        notifier.onOpenMeeting = { [weak self] id in
            self?.selectedMeetingID = id
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Moting" }?.makeKeyAndOrderFront(nil)
        }
        env.pipeline.onProgress = { [weak self] id, p in
            Task { @MainActor in
                guard let self else { return }
                self.progress[id] = p
                if id == self.lastRecordedMeetingID, p < 1 { self.lastStatus = .running }
            }
        }
        env.pipeline.onJobFinished = { [weak self] job in
            Task { @MainActor in self?.finished(job) }
        }
        let pipeline = env.pipeline
        powerMonitor = PowerMonitor { try? pipeline.powerChanged() }
        pipeline.start()
    }

    /// 录音结束后调用：入队（用电池时等待插电）
    /// 录音结束后调用：按"通用"设置决定是否自动精准转写、用电池时是否立即处理
    func enqueueAfterRecording(_ meetingID: UUID) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.autoTranscribeKey) as? Bool ?? true else { return }
        lastRecordedMeetingID = meetingID
        lastStatus = enqueue(meetingID)?.status
        if lastStatus == .waitingForPower, defaults.string(forKey: Self.batteryPolicyKey) == "now" {
            processNow(meetingID)
        }
    }

    @discardableResult
    func enqueue(_ meetingID: UUID) -> Job? {
        guard let env else { return nil }
        do {
            return try env.pipeline.enqueue(meetingID: meetingID, modelID: env.offlineModel.id)
        } catch {
            NSLog("会后处理入队失败：\(error)")
            return nil
        }
    }

    func processNow(_ meetingID: UUID) {
        try? env?.pipeline.processNow(meetingID: meetingID)
        if meetingID == lastRecordedMeetingID { lastStatus = .queued }
    }

    /// 录音状态变化时调用：录音结束要唤醒调度器
    func recordingChanged(_ isRecording: Bool) {
        env?.recordingFlag.isRecording = isRecording
        if !isRecording { env?.pipeline.wake() }
    }

    func dismissLastRecorded() {
        lastRecordedMeetingID = nil
        lastStatus = nil
    }

    private func finished(_ job: Job) {
        progress[job.meetingID] = nil
        if job.meetingID == lastRecordedMeetingID {
            lastStatus = job.status
            // 完成后悬浮窗停留几秒再收起；失败则保留，让用户看到
            if job.status == .done {
                let id = job.meetingID
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    if self?.lastRecordedMeetingID == id { self?.dismissLastRecorded() }
                }
            }
        }
        guard let env, let meeting = try? env.repository.meeting(job.meetingID) else { return }
        if job.status == .done {
            notifier.post(title: "精准转写已完成", body: meeting.title, meetingID: job.meetingID)
        } else {
            notifier.post(title: "精准转写失败", body: "\(meeting.title)：\(job.error ?? "未知错误")", meetingID: job.meetingID)
        }
    }
}

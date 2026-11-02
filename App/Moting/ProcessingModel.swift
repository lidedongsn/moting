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
    /// AI 纪要（与会后处理共用通知）
    let summary: SummaryModel
    private var powerMonitor: PowerMonitor?

    /// 请求打开主窗口；由常驻的菜单栏图标视图接收（悬浮窗、通知里拿不到 openWindow）
    static let openMainRequest = Notification.Name("moting.openMain")

    /// 在主窗口里打开某场会议的详情；主窗口关着也会重新打开
    func openMeeting(_ id: UUID) {
        selectedMeetingID = id
        NotificationCenter.default.post(name: Self.openMainRequest, object: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init(env: AppEnvironment?) {
        self.env = env
        summary = SummaryModel(env: env, notifier: notifier)
        guard let env else { return }
        notifier.requestAuthorization()
        notifier.onOpenMeeting = { [weak self] id in self?.openMeeting(id) }
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
    /// 太短的录音被丢弃时提示一下，免得以为没录上
    func noteDiscarded(seconds: TimeInterval) {
        notifier.post(title: "录音太短，已丢弃", body: "这次只录了 \(Int(seconds.rounded())) 秒，没有保存，也不会转写。", meetingID: nil)
    }

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

    /// 暂停精准转写：当前步骤中断，已完成的步骤保留
    func pause(_ meetingID: UUID) {
        try? env?.pipeline.pause(meetingID: meetingID)
        progress[meetingID] = nil
        if meetingID == lastRecordedMeetingID { lastStatus = .paused }
    }

    func resume(_ meetingID: UUID) {
        try? env?.pipeline.resume(meetingID: meetingID)
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
            summary.autoGenerateIfEnabled(job.meetingID)
        } else {
            notifier.post(title: "精准转写失败", body: "\(meeting.title)：\(job.error ?? "未知错误")", meetingID: job.meetingID)
        }
    }
}

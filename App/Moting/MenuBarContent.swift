import AppKit
import MotingCore
import SwiftUI

/// 菜单栏面板：平时是大号"开始录音"和最近会议；录音中只有计时、暂停 / 结束（字幕看悬浮窗，不在这里重复）
struct MenuBarContent: View {
    @ObservedObject var recorder: RecordingController
    @ObservedObject var processing: ProcessingModel
    let env: AppEnvironment?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var recent: [Meeting] = []
    @Environment(\.colorScheme) private var scheme

    private var isRecording: Bool {
        recorder.state == .recording || recorder.state == .paused || recorder.state == .stopping
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isRecording { recordingCard } else { startButton }
            if !isRecording && !recent.isEmpty {
                section(L("最近"))
                ForEach(recent) { m in
                    Button {
                        processing.selectedMeetingID = m.id
                        showMain()
                    } label: {
                        HStack {
                            Text(m.title).lineLimit(1)
                            Spacer()
                            Text(status(m)).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .font(.system(size: 13))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MenuRowStyle())
                }
            }
            Divider().padding(.vertical, 6).padding(.horizontal, 6)
            if isRecording {
                menuRow(L("标记重点")) { recorder.mark() }
                menuRow(L("显示字幕窗")) {
                    NotificationCenter.default.post(name: FloatingPanelController.showRequest, object: nil)
                    closePanel()
                }
            } else {
                menuRow(L("打开 Moting"), action: showMain)
                menuRow(L("设置…")) {
                    openSettings()
                    NSApp.activate(ignoringOtherApps: true)
                }
                menuRow(L("退出 Moting")) { NSApp.terminate(nil) }
            }
        }
        .padding(10)
        .frame(width: 280)
        .background(scheme == .dark ? Theme.chrome : .clear)
        .task(id: recorder.state) { loadRecent() }
    }

    private var startButton: some View {
        Button {
            recorder.start()
            // 字幕会出现在悬浮窗里，面板收起，不挡着
            closePanel()
        } label: {
            HStack(spacing: 8) {
                Circle().fill(.white).frame(width: 9, height: 9)
                Text(recorder.isStarting ? L("正在启动…") : L("开始录音")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("⌥⌘R").font(.system(size: 12)).opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Theme.record, in: RoundedRectangle(cornerRadius: Theme.Radius.button + 1, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(recorder.isStarting)
    }

    /// 录音中：计时，暂停 / 结束在右侧
    private var recordingCard: some View {
        let paused = recorder.state == .paused
        return HStack(spacing: 8) {
            Circle().fill(paused ? Color(nsColor: .systemOrange) : Theme.record).frame(width: 9, height: 9)
            Text(clock(recorder.elapsed)).font(.system(size: 17, weight: .semibold)).monospacedDigit()
            if paused { Text("已暂停").font(.system(size: 12)).foregroundStyle(.secondary) }
            Spacer()
            Button { paused ? recorder.resume() : recorder.pause() } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(AppButtonStyle(iconOnly: true))
            .help(paused ? L("继续") : L("暂停"))
            Button(recorder.isStopping ? L("正在结束…") : L("结束")) { recorder.stop() }
                .buttonStyle(AppButtonStyle(kind: .record))
                .disabled(recorder.isStopping)
        }
        .padding(.leading, 12).padding(.trailing, 8)
        .frame(height: 44)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.button + 1, style: .continuous))
    }

    private func menuRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuRowStyle())
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.top, 10).padding(.bottom, 2).padding(.horizontal, 8)
    }

    private func status(_ m: Meeting) -> String {
        switch m.status {
        case .processing: L("转写中 \(Int((processing.progress[m.id] ?? 0) * 100))%")
        case .pendingProcessing: L("待转写")
        case .failed: L("失败")
        case .recording: L("录音中")
        case .interrupted: L("录音中断")
        case .done:
            Calendar.current.isDateInToday(m.startedAt)
                ? m.startedAt.formatted(.dateTime.hour().minute())
                : m.startedAt.formatted(.dateTime.month().day())
        }
    }

    private func loadRecent() {
        guard let env else { return }
        let repo = env.repository
        Task.detached {
            let all = (try? repo.meetings(status: .done)) ?? []
            let others = [MeetingStatus.processing, .pendingProcessing, .failed].flatMap { (try? repo.meetings(status: $0)) ?? [] }
            let list = Array((all + others).sorted { $0.startedAt > $1.startedAt }.prefix(3))
            await MainActor.run { recent = list }
        }
    }

    /// 收起菜单栏面板（面板本身是当前的 key 窗口）
    private func closePanel() {
        NSApp.keyWindow?.close()
    }

    private func showMain() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// 菜单面板里可点的行：悬停时浅色高亮
private struct MenuRowStyle: ButtonStyle {
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background((configuration.isPressed || hover) ? Color.primary.opacity(0.08) : .clear,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            .onHover { hover = $0 }
    }
}

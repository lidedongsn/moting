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
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(MenuRowStyle())
                }
            }
            Divider().padding(.top, 10)
            HStack {
                if isRecording {
                    Button("★ 标记重点") { recorder.mark() }
                    Spacer()
                    Button("显示字幕窗") {
                        NotificationCenter.default.post(name: FloatingPanelController.showRequest, object: nil)
                        closePanel()
                    }
                } else {
                    Button("打开 Moting", action: showMain)
                    Spacer()
                    Button("设置…") {
                        openSettings()
                        NSApp.activate(ignoringOtherApps: true)
                    }
                    Button("退出") { NSApp.terminate(nil) }
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12.5))
            .foregroundStyle(.secondary)
            .padding(.top, 10)
        }
        .padding(14)
        .frame(width: 320)
        .background(scheme == .dark ? Theme.darkSidebar : .clear)
        .task(id: recorder.state) { loadRecent() }
    }

    private var startButton: some View {
        Button {
            recorder.start()
            // 字幕会出现在悬浮窗里，面板收起，不挡着
            closePanel()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().strokeBorder(.white, lineWidth: 3).frame(width: 22, height: 22)
                    Circle().fill(.white).frame(width: 9, height: 9)
                }
                Text(recorder.isStarting ? L("正在启动…") : L("开始录音")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("⌥⌘R").font(.system(size: 12)).opacity(0.85)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(Theme.record, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(recorder.isStarting)
    }

    /// 录音中：深色计时卡片（设计稿），暂停 / 结束在右侧
    private var recordingCard: some View {
        let paused = recorder.state == .paused
        return HStack(spacing: 12) {
            Circle().fill(paused ? Color.orange : Theme.record).frame(width: 10, height: 10)
                .background(Circle().fill((paused ? Color.orange : Theme.record).opacity(0.3)).frame(width: 18, height: 18))
            Text(clock(recorder.elapsed)).font(.system(size: 20, weight: .semibold)).monospacedDigit()
            if paused { Text("已暂停").font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)) }
            Spacer()
            Button {
                paused ? recorder.resume() : recorder.pause()
            } label: {
                Image(systemName: paused ? "play.fill" : "pause.fill").font(.system(size: 11, weight: .bold))
                    .frame(width: 34, height: 26)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(paused ? L("继续") : L("暂停"))
            Button { recorder.stop() } label: {
                Text(recorder.isStopping ? L("正在结束…") : L("结束")).font(.system(size: 12.5, weight: .semibold))
                    .padding(.horizontal, 11).frame(height: 26)
                    .background(Theme.record, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(recorder.isStopping)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .frame(height: 56)
        .background(Color(hex: 0x1C1C1F), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
            .padding(.top, 14).padding(.bottom, 4).padding(.horizontal, 2)
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

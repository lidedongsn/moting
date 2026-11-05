import MotingCapture
import MotingCore
import SwiftUI

/// 设置·通用
struct GeneralPane: View {
    @ObservedObject var recorder: RecordingController
    @StateObject private var mics = MicDevicesModel()
    @AppStorage(MicPreference.uidKey) private var micUID = ""
    @AppStorage(MicPreference.nameKey) private var micName = ""
    @AppStorage(AppLanguage.key) private var language = AppLanguage.system.rawValue
    @AppStorage(ProcessingModel.autoTranscribeKey) private var autoTranscribe = true
    @AppStorage(ProcessingModel.batteryPolicyKey) private var batteryPolicy = BatteryPolicy.now
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @AppStorage(CallDetector.enabledKey) private var callDetection = true
    @AppStorage(CalendarNaming.enabledKey) private var calendarNaming = false
    @State private var calendarDenied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: L("通用"), subtitle: L("外观、什么时候提醒录音，以及录音结束后怎么处理。"))
            PaneCard {
                row(title: L("外观"), detail: L("主窗口、设置和菜单栏面板的明暗；悬浮字幕窗始终是深色，方便叠在会议画面上看。")) {
                    PillTabs(selection: $appearance, items: AppAppearance.allCases.map { .init(value: $0.rawValue, title: $0.title) },
                             size: .small)
                }
            }
            .onChange(of: appearance) { _, v in (AppAppearance(rawValue: v) ?? .system).apply() }
            .padding(.bottom, 16)
            PaneCard {
                row(title: L("界面语言"), detail: L("默认跟随系统语言。切换后重启 Moting 生效；录音和转写内容不受影响。")) {
                    HStack(spacing: 8) {
                        if language != AppLanguage.atLaunch.rawValue {
                            Button(recorder.state == .recording || recorder.state == .paused ? L("录音结束后可重启") : L("立即重启")) {
                                AppLanguage.relaunch()
                            }
                            .buttonStyle(PaneButtonStyle(kind: .primary))
                            .disabled(recorder.state == .recording || recorder.state == .paused || recorder.state == .stopping)
                        }
                        Picker("", selection: $language) {
                            ForEach(AppLanguage.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
            }
            .onChange(of: language) { _, v in (AppLanguage(rawValue: v) ?? .system).save() }
            .padding(.bottom, 16)
            PaneCard {
                row(title: L("麦克风"), detail: L("下次开始录音时生效。选定的设备断开时，录音自动改用系统默认，不会中断。")) {
                    Picker("", selection: micSelection) {
                        Text(systemDefaultMicTitle).tag("")
                        ForEach(mics.devices) { Text($0.name).tag($0.uid) }
                        // 选过但现在没连接的设备，也要留在列表里
                        if !micUID.isEmpty, !mics.devices.contains(where: { $0.uid == micUID }) {
                            Text("\(micName)（未连接）").tag(micUID)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(.bottom, 16)
            PaneCard {
                row(title: L("发现会议时提醒录音"),
                    detail: L("腾讯会议、飞书、钉钉、Zoom 等开始用麦克风时，在屏幕右上角问要不要录；通话结束时提醒结束录音。只看哪个 app 在用麦克风，不会自动开始录音。")) {
                    Toggle("", isOn: $callDetection).toggleStyle(.switch).labelsHidden()
                }
                Divider().padding(.leading, 14)
                row(title: L("用日历事件给会议命名"),
                    detail: calendarDenied
                        ? L("没有日历权限。请在系统设置 › 隐私与安全性 › 日历 里允许 Moting，再打开这里。")
                        : L("开始录音时，用日历里正在开的会议标题代替「会议 日期 时间」。日历只在这台 Mac 上读取，不上传。")) {
                    Toggle("", isOn: Binding(get: { calendarNaming && CalendarNaming.isAuthorized }, set: { setCalendarNaming($0) }))
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            .padding(.bottom, 16)
            PaneCard {
                // 左侧文字、右侧控件，两行左边对齐（系统 Toggle 会给标签加缩进）
                row(title: L("录音结束后自动精准转写"),
                    detail: L("用离线大模型重新识别整段录音，生成带说话人的正式稿。关闭后可在会议详情里手动开始。")) {
                    Toggle("", isOn: $autoTranscribe).toggleStyle(.switch).labelsHidden()
                }
                Divider().padding(.leading, 14)
                row(title: L("使用电池时"), detail: L("1 小时的会议，精准转写大约需要几分钟。")) {
                    Picker("", selection: $batteryPolicy) {
                        Text("立即处理").tag(BatteryPolicy.now)
                        Text("等接通电源再处理").tag(BatteryPolicy.wait)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    private var systemDefaultMicTitle: String {
        mics.defaultName.map { L("跟随系统（\($0)）") } ?? L("跟随系统")
    }

    private var micSelection: Binding<String> {
        Binding(get: { micUID }, set: { uid in
            micUID = uid
            micName = mics.devices.first { $0.uid == uid }?.name ?? ""
        })
    }

    private func setCalendarNaming(_ on: Bool) {
        guard on else { calendarNaming = false; return }
        Task {
            let granted = CalendarNaming.isAuthorized ? true : await CalendarNaming.requestAccess()
            calendarDenied = !granted
            calendarNaming = granted
        }
    }

    private func row<Control: View>(title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            control()
        }
        .padding(14)
    }
}

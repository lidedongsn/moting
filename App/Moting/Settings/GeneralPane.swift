import SwiftUI

/// 设置·通用
struct GeneralPane: View {
    @AppStorage(ProcessingModel.autoTranscribeKey) private var autoTranscribe = true
    @AppStorage(ProcessingModel.batteryPolicyKey) private var batteryPolicy = "wait"
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.system.rawValue
    @AppStorage(CallDetector.enabledKey) private var callDetection = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "通用", subtitle: "外观、什么时候提醒录音，以及录音结束后怎么处理。")
            PaneCard {
                row(title: "外观", detail: "主窗口、设置和菜单栏面板的明暗；悬浮字幕窗始终是深色，方便叠在会议画面上看。") {
                    PillTabs(selection: $appearance, items: AppAppearance.allCases.map { .init(value: $0.rawValue, title: $0.title) },
                             size: .small)
                }
            }
            .onChange(of: appearance) { _, v in (AppAppearance(rawValue: v) ?? .system).apply() }
            .padding(.bottom, 16)
            PaneCard {
                row(title: "发现会议时提醒录音",
                    detail: "腾讯会议、飞书、钉钉、Zoom 等开始用麦克风时，在屏幕右上角问要不要录；通话结束时提醒结束录音。只看哪个 app 在用麦克风，不会自动开始录音。") {
                    Toggle("", isOn: $callDetection).toggleStyle(.switch).labelsHidden()
                }
            }
            .padding(.bottom, 16)
            PaneCard {
                // 左侧文字、右侧控件，两行左边对齐（系统 Toggle 会给标签加缩进）
                row(title: "录音结束后自动精准转写",
                    detail: "用离线大模型重新识别整段录音，生成带说话人的正式稿。关闭后可在会议详情里手动开始。") {
                    Toggle("", isOn: $autoTranscribe).toggleStyle(.switch).labelsHidden()
                }
                Divider().padding(.leading, 14)
                row(title: "使用电池时", detail: "精准转写会持续占用 CPU 几分钟，耗电较多。") {
                    Picker("", selection: $batteryPolicy) {
                        Text("等接通电源再处理").tag("wait")
                        Text("立即处理").tag("now")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
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

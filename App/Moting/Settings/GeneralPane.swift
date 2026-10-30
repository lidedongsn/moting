import SwiftUI

/// 设置·通用
struct GeneralPane: View {
    @AppStorage(ProcessingModel.autoTranscribeKey) private var autoTranscribe = true
    @AppStorage(ProcessingModel.batteryPolicyKey) private var batteryPolicy = "wait"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "通用", subtitle: "录音结束后怎么处理。")
            PaneCard {
                Toggle(isOn: $autoTranscribe) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("录音结束后自动精准转写")
                        Text("用离线大模型重新识别整段录音，生成带说话人的正式稿。关闭后可在会议详情里手动开始。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .padding(14)
                Divider().padding(.leading, 14)
                Picker(selection: $batteryPolicy) {
                    Text("等接通电源再处理").tag("wait")
                    Text("立即处理").tag("now")
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("使用电池时")
                        Text("精准转写会持续占用 CPU 几分钟，耗电较多。").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
        }
    }
}

/// 设置·AI 纪要（P4 接入前只放说明）
struct SummaryPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "AI 纪要", subtitle: "根据转写稿生成概要、决策和待办。")
            PaneCard {
                HStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.title2).foregroundStyle(.purple)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("还没有接入").font(.headline)
                        Text("接入后可以在这里配置大模型服务（例如 DeepSeek），转写稿只发送文字，不上传录音。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
            }
        }
    }
}

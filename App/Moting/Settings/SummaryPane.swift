import MotingSummary
import SwiftUI

/// 设置·AI 纪要：DeepSeek 的 API Key（存钥匙串）、模型、是否自动生成；醒目说明会发送什么
struct SummaryPane: View {
    @ObservedObject var model: SummaryModel
    @AppStorage(SummaryModel.autoKey) private var auto = false
    @State private var keyText = ""
    @State private var editingKey = false
    @State private var checking = false
    @State private var checkResult: (ok: Bool, text: String)?
    @State private var keyError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "AI 纪要", subtitle: "根据转写稿生成概要、决策和待办。")
            privacy.padding(.bottom, 16)
            Text("DeepSeek").font(.headline).padding(.bottom, 8)
            PaneCard {
                keyRow
                Divider().padding(.leading, 14)
                modelRow
            }
            Text("什么时候生成").font(.headline).padding(.top, 22).padding(.bottom, 8)
            PaneCard {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("精准转写完成后自动生成纪要")
                        Text(auto ? "每场会议转写完成后，会自动把转写文字发给 DeepSeek。"
                                  : "关闭时不会自动发送任何内容，在会议的「纪要」页点「生成纪要」才发送。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: $auto).toggleStyle(.switch).labelsHidden().disabled(!model.hasKey)
                }
                .padding(14)
            }
        }
    }

    /// 隐私说明：发什么、不发什么、Key 存哪里
    private var privacy: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield.fill").font(.system(size: 18)).foregroundStyle(Theme.me)
            VStack(alignment: .leading, spacing: 4) {
                Text("生成纪要时，会把这场会议的转写文字（含说话人名字和时间）发送给 DeepSeek。录音不会上传。")
                Text("API Key 只保存在这台 Mac 的钥匙串里，不写入任何文件，也不随 iCloud 同步。")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 12.5))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.me.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.me.opacity(0.25), lineWidth: 0.5))
    }

    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("API Key")
                    if model.hasKey && !editingKey {
                        Label("已保存在钥匙串", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                    } else {
                        HStack(spacing: 4) {
                            Text("在 DeepSeek 开放平台创建：").font(.caption).foregroundStyle(.secondary)
                            Link("platform.deepseek.com", destination: URL(string: "https://platform.deepseek.com/api_keys")!)
                                .font(.caption)
                        }
                    }
                }
                Spacer(minLength: 0)
                if model.hasKey && !editingKey {
                    Text("sk-••••••••").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.secondary)
                    Button("更换") { keyText = ""; editingKey = true }.buttonStyle(PaneButtonStyle())
                    Button("删除") { try? model.setKey(""); checkResult = nil; auto = false }.buttonStyle(PaneButtonStyle(kind: .danger))
                } else {
                    SecureField("sk-…", text: $keyText)
                        .textFieldStyle(.plain)
                        .paneInput()
                        .frame(width: 240)
                        .onSubmit(saveKey)
                    Button("保存", action: saveKey).buttonStyle(PaneButtonStyle(kind: .primary))
                        .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                    if editingKey { Button("取消") { editingKey = false; keyText = "" }.buttonStyle(PaneButtonStyle()) }
                }
            }
            if let keyError { Text(keyError).font(.caption).foregroundStyle(.orange) }
            if model.hasKey && !editingKey {
                HStack(spacing: 8) {
                    Button(checking ? "正在测试…" : "测试连接", action: check).buttonStyle(PaneButtonStyle()).disabled(checking)
                    if let r = checkResult {
                        Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(r.ok ? .green : .orange)
                            .lineLimit(2)
                    }
                }
            }
        }
        .padding(14)
    }

    private var modelRow: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("模型")
                Text(model.service.model == "deepseek-flash" ? "速度快、价格低，日常会议够用。" : "更强的理解和归纳，价格约为 Flash 的 4 倍。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            PillTabs(selection: $model.service.model, items: [
                .init(value: "deepseek-flash", title: "Flash"),
                .init(value: "deepseek-v4-pro", title: "V4 Pro"),
            ], size: .small)
        }
        .padding(14)
    }

    private func saveKey() {
        do {
            try model.setKey(keyText)
            keyText = ""
            editingKey = false
            keyError = nil
            check()
        } catch {
            keyError = error.localizedDescription
        }
    }

    private func check() {
        checking = true
        checkResult = nil
        Task {
            defer { checking = false }
            do {
                let models = try await model.testConnection()
                checkResult = (true, models.isEmpty ? "连接正常" : "连接正常，可用模型：\(models.joined(separator: "、"))")
            } catch {
                checkResult = (false, error.localizedDescription)
            }
        }
    }
}

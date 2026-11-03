import MotingSummary
import SwiftUI

/// 设置·AI 纪要：选服务（DeepSeek、通义千问、Kimi、智谱、豆包、OpenAI、本机 Ollama、自定义）、
/// API Key（按服务分别存钥匙串）、模型、是否自动生成；醒目说明会发送什么
struct SummaryPane: View {
    @ObservedObject var model: SummaryModel
    @AppStorage(SummaryModel.autoKey) private var auto = false
    @State private var keyText = ""
    @State private var editingKey = false
    @State private var checking = false
    @State private var checkResult: (ok: Bool, text: String)?
    @State private var keyError: String?

    private var service: SummaryService { model.service }
    /// 自定义和本机服务可以改地址
    private var addressEditable: Bool { service.id == "custom" || service.id == "ollama" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "AI 纪要", subtitle: "根据转写稿生成概要、决策和待办。")
            privacy.padding(.bottom, 16)
            Text("服务").font(.headline).padding(.bottom, 8)
            PaneCard {
                serviceRow
                Divider().padding(.leading, 14)
                addressRow
                Divider().padding(.leading, 14)
                modelRow
                if service.requiresKey {
                    Divider().padding(.leading, 14)
                    keyRow
                }
                Divider().padding(.leading, 14)
                checkRow
            }
            Text("什么时候生成").font(.headline).padding(.top, 22).padding(.bottom, 8)
            PaneCard {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("精准转写完成后自动生成纪要")
                        Text(auto ? "每场会议转写完成后，会自动把转写文字发给\(service.isLocal ? "本机模型" : " \(service.name)")。"
                                  : "关闭时不会自动发送任何内容，在会议的「纪要」页点「生成纪要」才发送。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Toggle("", isOn: $auto).toggleStyle(.switch).labelsHidden().disabled(!model.isReady)
                }
                .padding(14)
            }
        }
        .onChange(of: service.id) { _, _ in
            keyText = ""
            editingKey = false
            checkResult = nil
            keyError = nil
        }
    }

    /// 隐私说明：发什么、发给谁、Key 存哪里
    private var privacy: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: service.isLocal ? "desktopcomputer" : "lock.shield.fill").font(.system(size: 18)).foregroundStyle(Theme.me)
            VStack(alignment: .leading, spacing: 4) {
                if service.isLocal {
                    Text("纪要由这台 Mac 上的模型生成，转写文字不会离开这台电脑。")
                    Text("需要先安装并运行 Ollama，下载好模型。本机模型较慢，长会议会分段处理。").foregroundStyle(.secondary)
                } else {
                    Text("生成纪要时，会把这场会议的转写文字（含说话人名字和时间）发送给 \(service.name)。录音不会上传。")
                    Text("API Key 只保存在这台 Mac 的钥匙串里，不写入任何文件，也不随 iCloud 同步。").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12.5))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.me.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.me.opacity(0.25), lineWidth: 0.5))
    }

    private var serviceRow: some View {
        row("服务", detail: service.isLocal ? "数据不出这台 Mac" : "使用该服务的 OpenAI 兼容接口") {
            Picker("", selection: Binding(get: { service.id }, set: { model.select($0) })) {
                ForEach(SummaryService.presets, id: \.id) { p in
                    Text(p.name).tag(p.id)
                    if p.id == "openai" || p.id == "ollama" { Divider() }
                }
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var addressRow: some View {
        row("服务地址", detail: service.validationError ?? (addressEditable ? "只能用 https，本机服务除外" : "")) {
            if addressEditable {
                TextField("https://…/v1", text: $model.service.baseURL)
                    .textFieldStyle(.plain)
                    .paneInput()
                    .frame(width: 300)
            } else {
                Text(service.baseURL).font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var modelRow: some View {
        let choices = model.availableModels.isEmpty ? service.suggestedModels : model.availableModels
        return row("模型", detail: model.availableModels.isEmpty ? "可直接改名；测试连接后能从实际可用的模型里选" : "已从服务获取可用模型") {
            HStack(spacing: 6) {
                TextField("模型名", text: $model.service.model)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .paneInput()
                    .frame(width: 220)
                if !choices.isEmpty {
                    Menu {
                        ForEach(choices, id: \.self) { m in Button(m) { model.service.model = m } }
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .menuStyle(.button)
                    .menuIndicator(.hidden)
                    .buttonStyle(PaneButtonStyle())
                    .fixedSize()
                    .help("选择模型")
                }
            }
        }
    }

    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("API Key")
                    if model.hasKey && !editingKey {
                        Label("已保存在钥匙串", systemImage: "checkmark.seal.fill").font(.caption).foregroundStyle(.green)
                    } else if let page = service.keyPage, let url = URL(string: page) {
                        HStack(spacing: 4) {
                            Text("在 \(service.name) 控制台创建：").font(.caption).foregroundStyle(.secondary)
                            Link(url.host ?? page, destination: url).font(.caption)
                        }
                    }
                }
                Spacer(minLength: 0)
                if model.hasKey && !editingKey {
                    Text("sk-••••••••").font(.system(size: 12.5, design: .monospaced)).foregroundStyle(.secondary)
                    Button("更换") { keyText = ""; editingKey = true }.buttonStyle(PaneButtonStyle())
                    Button("删除") { try? model.setKey(""); checkResult = nil; auto = false }.buttonStyle(PaneButtonStyle(kind: .danger))
                } else {
                    SecureField("粘贴 API Key", text: $keyText)
                        .textFieldStyle(.plain)
                        .paneInput()
                        .frame(width: 220)
                        .onSubmit(saveKey)
                    Button("保存", action: saveKey).buttonStyle(PaneButtonStyle(kind: .primary))
                        .disabled(keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                    if editingKey { Button("取消") { editingKey = false; keyText = "" }.buttonStyle(PaneButtonStyle()) }
                }
            }
            if let keyError { Text(keyError).font(.caption).foregroundStyle(.orange) }
        }
        .padding(14)
    }

    private var checkRow: some View {
        HStack(spacing: 8) {
            Button(checking ? "正在测试…" : "测试连接", action: check).buttonStyle(PaneButtonStyle())
                .disabled(checking || !model.isReady || service.validationError != nil)
            if let r = checkResult {
                Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(r.ok ? .green : .orange)
                    .lineLimit(2)
            } else if !model.isReady {
                Text("先填写 API Key").font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func row<Control: View>(_ title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
            control()
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
                checkResult = (true, models.isEmpty ? "连接正常" : "连接正常，有 \(models.count) 个可用模型")
            } catch {
                checkResult = (false, error.localizedDescription)
            }
        }
    }
}

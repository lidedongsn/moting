import MotingCore
import MotingStorage
import SwiftUI

/// 纪要页（设计稿"主窗口·纪要"）：左边概要 / 决策 / 议题，右边待办；没有纪要时说明会发送什么再让用户点
struct SummaryView: View {
    let meetingID: UUID
    @ObservedObject var model: SummaryModel
    let hasTranscript: Bool
    @Environment(\.openSettings) private var openSettings
    @State private var stored: StoredSummary?
    @State private var showRaw = false

    var body: some View {
        Group {
            if model.generating.contains(meetingID) {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在生成纪要…").font(.system(size: 13, weight: .semibold))
                    Text(model.service.isLocal ? "正在用本机模型生成，可能需要几分钟。" : "已把转写文字发送给 \(model.service.name)，通常几十秒。").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let s = stored?.summary {
                content(s)
            } else {
                empty
            }
        }
        .task(id: "\(meetingID)-\(model.revision)") { stored = model.stored(meetingID) }
    }

    // MARK: - 有纪要

    private func content(_ s: MeetingSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    if let error = model.errors[meetingID] {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    }
                    Spacer()
                    if let st = stored {
                        Text("由 \(st.provider) 生成 · \(st.createdAt.formatted(.dateTime.month().day().hour().minute()))")
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                    Button { model.generate(meetingID) } label: { Label("重新生成", systemImage: "arrow.clockwise") }
                        .buttonStyle(ToolbarPillStyle())
                        .help("会再次把转写文字发送给 \(model.service.name)")
                }
                // 宽时左右两栏，窄时待办放到下面
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 36) {
                        mainColumn(s).frame(minWidth: 420, maxWidth: .infinity, alignment: .leading)
                        todoColumn(s).frame(width: 300, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 26) {
                        mainColumn(s)
                        todoColumn(s)
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 14)
        }
    }

    private func mainColumn(_ s: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            section("概要") {
                Text(s.overview).font(.system(size: 14.5)).lineSpacing(5).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !s.decisions.isEmpty {
                section("决策") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(s.decisions, id: \.self) { bullet($0) }
                    }
                }
            }
            if !s.topics.isEmpty {
                section("议题") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(s.topics, id: \.title) { t in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(t.title).font(.system(size: 14, weight: .semibold))
                                ForEach(t.points, id: \.self) { bullet($0) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func todoColumn(_ s: MeetingSummary) -> some View {
        section("待办") {
            if s.todos.isEmpty {
                Text("会上没有明确的待办。").font(.system(size: 13)).foregroundStyle(.tertiary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(s.todos) { todo($0) }
                }
            }
        }
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            content()
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(.tertiary).frame(width: 4, height: 4).alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
            Text(text).font(.system(size: 14)).lineSpacing(3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func todo(_ t: MeetingSummary.Todo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button { model.setTodo(meetingID, t.id, done: !t.done) } label: {
                Image(systemName: t.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(t.done ? Theme.me : Color.secondary)
            }
            .buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 3) {
                Text(t.task).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                    .strikethrough(t.done).foregroundStyle(t.done ? .secondary : .primary)
                    .textSelection(.enabled)
                let meta = [t.owner, t.due].compactMap { $0 }
                if !meta.isEmpty { Text(meta.joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }

    // MARK: - 还没有纪要

    private var empty: some View {
        VStack(spacing: 12) {
            // 与 app 图标同一组青→紫
            Image(systemName: "sparkles").font(.system(size: 30))
                .foregroundStyle(LinearGradient(colors: [Color(hex: 0x2BB8F0), Color(hex: 0x6D3FE0)], startPoint: .topLeading, endPoint: .bottomTrailing))
            if !model.isReady {
                Text("先配置 AI 纪要服务").font(.system(size: 17, weight: .semibold))
                Text("在设置里选择服务（DeepSeek、通义千问、Kimi 等）并填写 API Key 后，就能根据转写稿生成概要、决策和待办。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Button {
                    UserDefaults.standard.set("summary", forKey: SettingsRoot.paneKey)
                    openSettings()
                } label: { Label("打开设置", systemImage: "gearshape") }
                .buttonStyle(AccentPillStyle())
                .padding(.top, 4)
            } else if !hasTranscript {
                Text("还没有转写内容").font(.system(size: 17, weight: .semibold))
                Text("转写完成后可以生成纪要。").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                Text("生成会议纪要").font(.system(size: 17, weight: .semibold))
                Text(model.service.isLocal
                     ? "用本机的 \(model.service.model) 根据转写文字生成概要、决策和待办，数据不出这台 Mac。"
                     : "会把这场会议的转写文字（不含录音）发送给 \(model.service.name)，生成概要、决策和待办。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Button { model.generate(meetingID) } label: { Label("生成纪要", systemImage: "sparkles") }
                    .buttonStyle(AccentPillStyle())
                    .padding(.top, 4)
            }
            if let error = model.errors[meetingID] {
                Text(error).font(.system(size: 12)).foregroundStyle(.orange).padding(.top, 4)
            }
            if let raw = stored?.raw, stored?.summary == nil {
                Button(showRaw ? "收起模型原文" : "查看模型原文") { showRaw.toggle() }.buttonStyle(.link).font(.system(size: 12))
                if showRaw {
                    ScrollView { Text(raw).font(.system(size: 12, design: .monospaced)).textSelection(.enabled) }
                        .frame(maxWidth: 520, maxHeight: 160)
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

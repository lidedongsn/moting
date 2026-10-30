import AppKit
import MotingCore
import MotingStorage
import SwiftUI
import UniformTypeIdentifiers

/// 会议详情：改名、回放、重点标记、转写稿（点句跳转）、导出与删除
struct MeetingDetailView: View {
    let meeting: Meeting
    let env: AppEnvironment
    let onDelete: (Meeting) -> Void
    @ObservedObject var recorder: RecordingController

    @StateObject private var player: MeetingPlayer
    @State private var title: String
    @State private var editingTitle = false
    @FocusState private var titleFocused: Bool
    @State private var segments: [TranscriptSegment] = []
    @State private var marks: [Mark] = []
    @State private var transcriptKind: TranscriptKind?

    init(meeting: Meeting, env: AppEnvironment, recorder: RecordingController, onDelete: @escaping (Meeting) -> Void) {
        self.meeting = meeting
        self.env = env
        self.recorder = recorder
        self.onDelete = onDelete
        _title = State(initialValue: meeting.title)
        _player = StateObject(wrappedValue: MeetingPlayer(urls: AudioChannel.allCases.map { env.paths.trackURL(meeting.id, $0) }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            playerBar
            if !marks.isEmpty {
                marksBar
            }
            Divider()
            transcript
        }
        .task(id: meeting.status) { load() }
        // 从列表右键改名后同步过来
        .onChange(of: meeting.title) { _, newTitle in
            if !editingTitle { title = newTitle }
        }
        .onDisappear { player.close() }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            titleRow
            HStack(spacing: 12) {
                Label(meeting.startedAt.formatted(date: .long, time: .shortened), systemImage: "calendar")
                if let end = meeting.endedAt {
                    Label(end.timeIntervalSince(meeting.startedAt).clockText, systemImage: "clock")
                }
                Label(ByteCountFormatter.string(fromByteCount: env.paths.diskUsage(of: meeting.id), countStyle: .file),
                      systemImage: "internaldrive")
                Text(meeting.status.displayName)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                Spacer()
                Button("导出 Markdown", systemImage: "square.and.arrow.up", action: exportMarkdown)
                Button("在 Finder 中显示", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([env.paths.meetingDirectory(meeting.id)])
                }
                Button("删除", systemImage: "trash", role: .destructive) { onDelete(meeting) }
                    .disabled(meeting.status == .recording)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
        .padding(16)
    }

    // 标题：点铅笔或双击进入编辑；回车或点别处保存，Esc 取消
    @ViewBuilder
    private var titleRow: some View {
        if editingTitle {
            TextField("会议标题", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.title2.weight(.semibold))
                .focused($titleFocused)
                .onSubmit(commitTitle)
                .onExitCommand(perform: cancelTitle)
                .onChange(of: titleFocused) { _, focused in
                    if !focused { commitTitle() }
                }
                .onAppear { titleFocused = true }
        } else {
            HStack(spacing: 8) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .onTapGesture(count: 2) { editingTitle = true }
                Button {
                    editingTitle = true
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("重命名")
            }
        }
    }

    // MARK: - 回放

    private var playerBar: some View {
        HStack(spacing: 10) {
            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .keyboardShortcut(editingTitle ? nil : KeyboardShortcut(.space, modifiers: []))
            .disabled(player.duration == 0)
            Text(player.currentTime.clockText).monospacedDigit().font(.callout)
            Slider(value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                   in: 0...max(player.duration, 0.1))
            Text(player.duration.clockText).monospacedDigit().font(.callout).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var marksBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(marks) { mark in
                    Button("★ \(MarkdownExporter.clock(mark.at))") {
                        player.seek(to: max(0, mark.at - 5))
                        player.play()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("跳到标记前 5 秒")
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 8)
    }

    // MARK: - 转写稿

    @ViewBuilder
    private var transcript: some View {
        if segments.isEmpty {
            ContentUnavailableView("暂无转写内容", systemImage: "text.bubble",
                                   description: Text("这场会议录音时没有实时字幕（例如当时还没下载识别模型）。会后精准转写将在后续版本加入。"))
        } else {
            ScrollViewReader { proxy in
                List(segments) { s in
                    segmentRow(s)
                        .id(s.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            player.seek(to: s.start)
                            player.play()
                        }
                        .listRowBackground(isCurrent(s) ? Color.accentColor.opacity(0.15) : Color.clear)
                }
                .onChange(of: currentSegmentID) { _, id in
                    if player.isPlaying, let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let kind = transcriptKind {
                    Text(kind == .draft ? "实时字幕草稿" : "精准转写")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(6)
                }
            }
        }
    }

    private func segmentRow(_ s: TranscriptSegment) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(MarkdownExporter.clock(s.start))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            // 浅色背景下黄色文字看不清：用彩色圆点标识，名字用正常文字色
            HStack(spacing: 4) {
                Circle()
                    .fill(s.channel == .mic ? FloatingPanelView.micColor : FloatingPanelView.systemColor)
                    .frame(width: 7, height: 7)
                Text(MarkdownExporter.speakerName(s)).font(.callout.weight(.medium))
            }
            .frame(width: 52, alignment: .leading)
            Text(s.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private var currentSegmentID: UUID? {
        segments.last { $0.start <= player.currentTime }?.id
    }

    private func isCurrent(_ s: TranscriptSegment) -> Bool {
        player.currentTime > 0 && s.id == currentSegmentID
    }

    // MARK: - 数据

    private func load() {
        marks = (try? env.repository.marks(meeting.id)) ?? []
        // 有正式稿用正式稿（P3），否则用实时草稿
        for kind in [TranscriptKind.final, .draft] {
            if let v = try? env.transcripts.latestVersion(meetingID: meeting.id, kind: kind) {
                segments = (try? env.transcripts.segments(versionID: v)) ?? []
                transcriptKind = kind
                return
            }
        }
        segments = []
        transcriptKind = nil
    }

    private func commitTitle() {
        guard editingTitle else { return }
        editingTitle = false
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            title = meeting.title
            return
        }
        title = trimmed
        do {
            try env.repository.rename(meeting.id, to: trimmed)
        } catch {
            recorder.lastError = "改名失败：\(error.localizedDescription)"
        }
    }

    private func cancelTitle() {
        title = meeting.title
        editingTitle = false
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = "\(title.replacingOccurrences(of: "/", with: "-")).md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var m = meeting
        m.title = title
        let md = MarkdownExporter.export(meeting: m, segments: segments, marks: marks)
        do {
            try md.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            recorder.lastError = "导出失败：\(error.localizedDescription)"
        }
    }
}

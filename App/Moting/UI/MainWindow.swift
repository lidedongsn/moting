import AppKit
import MotingCore
import MotingStorage
import SwiftUI

/// 主窗口：侧栏（搜索、按日期分组、迷你声纹条、存储用量）+ 会议详情
struct MainWindow: View {
    let env: AppEnvironment
    @ObservedObject var recorder: RecordingController
    @ObservedObject var processing: ProcessingModel

    @Environment(\.openSettings) private var openSettings
    @State private var meetings: [Meeting] = []
    @State private var query = ""
    @State private var matched: Set<UUID> = []
    @State private var usage: (recordings: Int64, models: Int64) = (0, 0)
    @State private var pendingDelete: Meeting?
    @State private var renaming: Meeting?
    @State private var renameText = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 250, ideal: 286, max: 380)
        } detail: {
            ZStack {
                if let m = meetings.first(where: { $0.id == processing.selectedMeetingID }) {
                    DetailView(meeting: m, env: env, recorder: recorder, processing: processing) { pendingDelete = $0 }
                        .id(m.id)
                } else {
                    ContentUnavailableView {
                        Label(meetings.isEmpty ? "还没有会议记录" : "选择一场会议", systemImage: "waveform")
                    } description: {
                        Text(meetings.isEmpty ? "开会时点右上角的「开始录音」，或按 ⌥⌘R。" : "在左侧选择会议，查看转写稿、回放录音。")
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { RecordButton(recorder: recorder) }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            do {
                for try await list in env.repository.observeAll() {
                    meetings = list
                    if processing.selectedMeetingID == nil { processing.selectedMeetingID = list.first?.id }
                    refreshUsage()
                }
            } catch {
                recorder.lastError = "读取会议列表失败：\(error.localizedDescription)"
            }
        }
        .task(id: query) {
            // 转写内容搜索放后台，输入时不卡
            let q = query, transcripts = env.transcripts
            matched = await Task.detached { (try? transcripts.meetingIDs(matching: q)) ?? [] }.value
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let m = pendingDelete { delete(m) } }
        } message: {
            Text("录音文件、转写稿和会议记录会被永久删除，无法恢复。")
        }
        .alert("重命名会议", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("会议标题", text: $renameText)
            Button("保存") {
                if let m = renaming { try? env.repository.rename(m.id, to: renameText) }
                renaming = nil
            }
            Button("取消", role: .cancel) { renaming = nil }
        }
    }

    // MARK: - 侧栏

    private var filtered: [Meeting] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return meetings }
        return meetings.filter { $0.title.localizedCaseInsensitiveContains(q) || matched.contains($0.id) }
    }

    private var sidebar: some View {
        List(selection: $processing.selectedMeetingID) {
            ForEach(MeetingGrouping.group(filtered, now: Date(), calendar: .current), id: \.0) { group, items in
                Section(group.rawValue) {
                    ForEach(items) { m in
                        MeetingRow(meeting: m, env: env, processing: processing)
                            .tag(m.id)
                            .contextMenu {
                                Button("重命名…") { renameText = m.title; renaming = m }
                                Button("在 Finder 中显示") {
                                    NSWorkspace.shared.activateFileViewerSelecting([env.paths.meetingDirectory(m.id)])
                                }
                                Divider()
                                Button("删除会议…", role: .destructive) { pendingDelete = m }
                                    .disabled(m.status == .recording)
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: $query, placement: .sidebar, prompt: "搜索会议和转写内容")
        .overlay {
            if !query.isEmpty && filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .safeAreaInset(edge: .bottom) { storageCard }
    }

    private var storageCard: some View {
        let total = usage.recordings + usage.models
        let fraction = { (n: Int64) in total > 0 ? CGFloat(n) / CGFloat(max(total, 1)) : 0 }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("占用 \(bytes(total))")
                Spacer()
                Button("管理") {
                    UserDefaults.standard.set("storage", forKey: SettingsRoot.paneKey)
                    openSettings()
                }
                .buttonStyle(.link)
            }
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle().fill(Theme.me).frame(width: geo.size.width * fraction(usage.recordings))
                    Rectangle().fill(Color.secondary.opacity(0.6)).frame(width: geo.size.width * fraction(usage.models))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 5)
            .background(Color.secondary.opacity(0.15))
            .clipShape(Capsule())
            Text("录音 \(bytes(usage.recordings)) · 模型 \(bytes(usage.models))").foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(12)
        .glassCard(radius: 10, material: .thinMaterial)
        .padding(10)
    }

    private var deleteTitle: String {
        guard let m = pendingDelete else { return "" }
        return "删除「\(m.title)」？将释放 \(bytes(env.paths.diskUsage(of: m.id)))"
    }

    private func refreshUsage() {
        let paths = env.paths
        Task.detached {
            let u = (paths.meetingsDiskUsage(), paths.modelsDiskUsage())
            await MainActor.run { usage = u }
        }
    }

    private func delete(_ m: Meeting) {
        do {
            // 先删文件再删记录：文件删除失败时记录还在，可以再试
            let dir = env.paths.meetingDirectory(m.id)
            if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
            if processing.selectedMeetingID == m.id { processing.selectedMeetingID = nil }
            try env.repository.delete(m.id)
            RibbonCache.shared.invalidate(m.id)
        } catch {
            recorder.lastError = "删除失败：\(error.localizedDescription)"
        }
        pendingDelete = nil
    }

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

/// 侧栏的一行：标题、状态标签、时间与时长、人数、迷你声纹条
struct MeetingRow: View {
    let meeting: Meeting
    let env: AppEnvironment
    @ObservedObject var processing: ProcessingModel
    @State private var timeline: [Color?] = []
    @State private var peopleCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(meeting.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 4)
                tag
            }
            HStack {
                Text(timeText)
                Spacer()
                if peopleCount > 1 { Text("\(peopleCount) 人") }
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            MiniTimeline(colors: timeline.isEmpty ? Array(repeating: nil, count: 60) : timeline)
                .padding(.top, 3)
        }
        .padding(.vertical, 5)
        .task(id: "\(meeting.id)-\(meeting.status.rawValue)") { loadTimeline() }
    }

    @ViewBuilder
    private var tag: some View {
        switch meeting.status {
        case .recording: StatusTag(text: "录音中", tint: Theme.record)
        case .processing: StatusTag(text: "转写中 \(Int((processing.progress[meeting.id] ?? 0) * 100))%", tint: Theme.me)
        case .failed: StatusTag(text: "失败", tint: .orange)
        case .interrupted: StatusTag(text: "录音中断", tint: .orange)
        case .pendingProcessing: StatusTag(text: "待转写", tint: .secondary)
        case .done: EmptyView()
        }
    }

    private var timeText: String {
        let start = Calendar.current.isDateInToday(meeting.startedAt) || Calendar.current.isDateInYesterday(meeting.startedAt)
            ? meeting.startedAt.formatted(.dateTime.hour().minute())
            : meeting.startedAt.formatted(.dateTime.month().day().hour().minute())
        guard let end = meeting.endedAt else { return start }
        return "\(start) · \(durationText(end.timeIntervalSince(meeting.startedAt)))"
    }

    private func loadTimeline() {
        let t = env.transcripts, id = meeting.id
        let duration = (meeting.endedAt ?? Date()).timeIntervalSince(meeting.startedAt)
        Task.detached(priority: .utility) {
            let v = (try? t.latestVersion(meetingID: id, kind: .final)) ?? (try? t.latestVersion(meetingID: id, kind: .draft)) ?? nil
            let segs = v.flatMap { try? t.segments(versionID: $0) } ?? []
            let idx = SpeakerPalette.indices(for: segs)
            let keys = SpeakingTimeline.bins(segs, duration: duration, count: 60)
            let people = Set(segs.map(\.speakerKey)).count
            await MainActor.run {
                timeline = keys.map { $0.map { Theme.speaker($0, in: idx) } }
                peopleCount = people
            }
        }
    }
}

/// 工具栏的录音按钮：平时为红色胶囊"开始录音"，录音中为计时 + 结束
struct RecordButton: View {
    @ObservedObject var recorder: RecordingController

    var body: some View {
        switch recorder.state {
        case .recording, .paused, .stopping:
            HStack(spacing: 8) {
                Circle().fill(Theme.record).frame(width: 8, height: 8)
                Text(clock(recorder.elapsed)).monospacedDigit().font(.system(size: 13, weight: .semibold))
                Button(recorder.isStopping ? "正在结束…" : "结束") { recorder.stop() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.record)
                    .controlSize(.small)
                    .disabled(recorder.isStopping)
            }
            .padding(.horizontal, 6)
        default:
            Button { recorder.start() } label: {
                Label(recorder.isStarting ? "正在启动…" : "开始录音", systemImage: "record.circle")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.record)
            .disabled(recorder.isStarting)
            .help("开始录音（⌥⌘R，任何 app 里都能按）")
        }
    }
}

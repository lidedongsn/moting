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
    @Environment(\.colorScheme) private var scheme
    @State private var meetings: [Meeting] = []
    @State private var query = ""
    @State private var matched: Set<UUID> = []
    @State private var usage: (recordings: Int64, models: Int64) = (0, 0)
    /// 待确认删除的会议（可多场）
    @State private var pendingDelete: [Meeting] = []
    /// 多选时选中的会议；为空表示只选中了当前这一场（processing.selectedMeetingID）
    @State private var marked: Set<UUID> = []
    @State private var renaming: Meeting?
    @State private var renameText = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                // 浅色：侧栏透出的桌面偏暗，叠一层白玻璃（设计稿 .side 42% 白）
                .background(scheme == .light ? Color.white.opacity(0.45) : .clear)
                .navigationSplitViewColumnWidth(min: 250, ideal: 286, max: 380)
        } detail: {
            ZStack {
                if let m = meetings.first(where: { $0.id == processing.selectedMeetingID }) {
                    DetailView(meeting: m, env: env, recorder: recorder, processing: processing) { pendingDelete = [$0] }
                        // 录音结束时重建一次：播放器在录音中创建时文件还是空的，时长为 0
                        .id("\(m.id)|\(m.endedAt?.timeIntervalSince1970 ?? 0)")
                } else {
                    ContentUnavailableView {
                        Label(meetings.isEmpty ? "还没有会议记录" : "选择一场会议", systemImage: "waveform")
                    } description: {
                        Text(meetings.isEmpty ? "开会时点右上角的「开始录音」，或按 ⌥⌘R。" : "在左侧选择会议，查看转写稿、回放录音。")
                    }
                }
            }
            // 浅色：系统窗口底是灰的，按设计稿在内容区叠一层白（.main 55% 白），深色不变
            .background { if scheme == .light { Color.white.opacity(0.6).ignoresSafeArea() } }
            .toolbar {
                // 有会议时录音按钮由详情页放在工具栏最右；没有选中会议时放在这里
                if processing.selectedMeetingID == nil || !meetings.contains(where: { $0.id == processing.selectedMeetingID }) {
                    ToolbarItem(placement: .primaryAction) { RecordButton(recorder: recorder) }
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        // 设计稿里工具栏和内容连成一片，不要分隔线
        .toolbarBackground(.hidden, for: .windowToolbar)
        // 标题留空而不是移除：移除后工具栏按钮会挤到左边
        .navigationTitle("")
        .task {
            do {
                for try await list in env.repository.observeAll() {
                    meetings = list
                    marked.formIntersection(list.map(\.id))
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
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
                            titleVisibility: .visible) {
            Button(pendingDelete.count > 1 ? "删除 \(pendingDelete.count) 场" : "删除", role: .destructive) { delete(pendingDelete) }
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
        // 不用系统选中（实心蓝底会盖住声纹条），自己画浅色选中底（设计稿 .mrow.on）
        List {
            ForEach(MeetingGrouping.group(filtered, now: Date(), calendar: .current), id: \.0) { group, items in
                Section(group.rawValue) {
                    ForEach(items) { m in
                        let on = picked.contains(m.id)
                        MeetingRow(meeting: m, env: env, processing: processing)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                            .onTapGesture { click(m.id) }
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(on ? Theme.me.opacity(0.16) : .clear)
                                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                        .strokeBorder(on ? Theme.me.opacity(0.35) : .clear, lineWidth: 0.5))
                                    .padding(.horizontal, 8)
                            )
                            .contextMenu { rowMenu(m) }
                            // 触控板左滑删除
                            .swipeActions(edge: .trailing) {
                                Button("删除", role: .destructive) { requestDelete([m]) }
                                    .disabled(m.status == .recording)
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .focusable()
        .focusEffectDisabled()
        .onMoveCommand { dir in moveSelection(dir) }
        // ⌫ 删除选中的会议；⌘A 全选；Esc 取消多选；回车重命名
        .onDeleteCommand { requestDelete(pickedMeetings) }
        .onCommand(#selector(NSResponder.selectAll(_:))) { marked = Set(orderedIDs) }
        .onExitCommand { marked = [] }
        .onKeyPress(.return) {
            guard marked.count <= 1, let m = meetings.first(where: { $0.id == processing.selectedMeetingID }) else { return .ignored }
            renameText = m.title
            renaming = m
            return .handled
        }
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

    // MARK: - 选择与管理

    /// 侧栏里从上到下的会议 id
    private var orderedIDs: [UUID] {
        MeetingGrouping.group(filtered, now: Date(), calendar: .current).flatMap { $0.1.map(\.id) }
    }

    /// 当前选中的全部会议：多选时是 marked，否则就是正在看的那一场
    private var picked: Set<UUID> {
        if !marked.isEmpty { return marked }
        return processing.selectedMeetingID.map { [$0] } ?? []
    }

    private var pickedMeetings: [Meeting] {
        meetings.filter { picked.contains($0.id) }
    }

    /// 单击切换会议；⌘ 单击加选 / 取消，⇧ 单击从当前会议连选到这里（同 Finder）
    private func click(_ id: UUID) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            var s = picked
            if s.contains(id), s.count > 1 {
                s.remove(id)
                if processing.selectedMeetingID == id { processing.selectedMeetingID = orderedIDs.first(where: s.contains) }
            } else {
                s.insert(id)
                processing.selectedMeetingID = id
            }
            marked = s.count > 1 ? s : []
        } else if flags.contains(.shift), let anchor = processing.selectedMeetingID,
                  let a = orderedIDs.firstIndex(of: anchor), let b = orderedIDs.firstIndex(of: id) {
            let range = Set(orderedIDs[min(a, b)...max(a, b)])
            marked = range.count > 1 ? range : []
        } else {
            marked = []
            processing.selectedMeetingID = id
        }
    }

    @ViewBuilder
    private func rowMenu(_ m: Meeting) -> some View {
        // 在多选范围内右键：对所有选中的会议操作
        let group = picked.contains(m.id) && picked.count > 1 ? pickedMeetings : [m]
        if group.count > 1 {
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting(group.map { env.paths.meetingDirectory($0.id) })
            }
            Divider()
            Button("删除 \(group.count) 场会议…", role: .destructive) { requestDelete(group) }
        } else {
            Button("重命名…") { renameText = m.title; renaming = m }
            Button("精准转写") { processing.enqueue(m.id) }
                .disabled(m.status == .recording || m.status == .processing)
            Button("在 Finder 中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([env.paths.meetingDirectory(m.id)])
            }
            Divider()
            Button("删除会议…", role: .destructive) { requestDelete([m]) }
                .disabled(m.status == .recording)
        }
    }

    /// 请求删除；正在录音的那场跳过
    private func requestDelete(_ list: [Meeting]) {
        let deletable = list.filter { $0.status != .recording }
        if !deletable.isEmpty { pendingDelete = deletable }
    }

    /// 上下方向键切换会议（同时退出多选）
    private func moveSelection(_ dir: MoveCommandDirection) {
        marked = []
        let ids = orderedIDs
        guard !ids.isEmpty else { return }
        let i = ids.firstIndex(where: { $0 == processing.selectedMeetingID })
        switch dir {
        case .up: processing.selectedMeetingID = ids[max(0, (i ?? 0) - 1)]
        case .down: processing.selectedMeetingID = ids[min(ids.count - 1, (i ?? -1) + 1)]
        default: break
        }
    }

    private var deleteTitle: String {
        let size = pendingDelete.reduce(Int64(0)) { $0 + env.paths.diskUsage(of: $1.id) }
        if pendingDelete.count == 1 { return "删除「\(pendingDelete[0].title)」？将释放 \(bytes(size))" }
        return "删除 \(pendingDelete.count) 场会议？将释放 \(bytes(size))"
    }

    private func refreshUsage() {
        let paths = env.paths
        Task.detached {
            let u = (paths.meetingsDiskUsage(), paths.modelsDiskUsage())
            await MainActor.run { usage = u }
        }
    }

    private func delete(_ list: [Meeting]) {
        let ids = Set(list.map(\.id))
        // 删完选中紧挨着的下一场（没有就上一场），不跳回列表顶部
        if let current = processing.selectedMeetingID, ids.contains(current) {
            let order = orderedIDs
            let i = order.firstIndex(of: current) ?? 0
            processing.selectedMeetingID = order[i...].first { !ids.contains($0) } ?? order[..<i].last { !ids.contains($0) }
        }
        marked = []
        var failed: [String] = []
        for m in list {
            do {
                // 先删文件再删记录：文件删除失败时记录还在，可以再试
                let dir = env.paths.meetingDirectory(m.id)
                if FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.removeItem(at: dir) }
                try env.repository.delete(m.id)
                RibbonCache.shared.invalidate(m.id)
            } catch {
                failed.append("「\(m.title)」：\(error.localizedDescription)")
            }
        }
        if !failed.isEmpty { recorder.lastError = "删除失败\n" + failed.joined(separator: "\n") }
        pendingDelete = []
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
    @State private var hovering = false

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
            // 工具栏会把标准按钮压成纯图标，这里自绘红色胶囊
            Button { recorder.start() } label: {
                HStack(spacing: 7) {
                    Circle().fill(.white).frame(width: 9, height: 9)
                    Text(recorder.isStarting ? "正在启动…" : "开始录音").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.leading, 11).padding(.trailing, 13)
                .frame(height: 28)
                .background(LinearGradient(colors: [Color(hex: 0xFF4B4F), Color(hex: 0xE5262B)], startPoint: .top, endPoint: .bottom),
                            in: Capsule())
                .brightness(hovering && !recorder.isStarting ? 0.1 : 0)
                .shadow(color: Theme.record.opacity(hovering ? 0.5 : 0.35), radius: hovering ? 7 : 5, y: 2)
                .animation(.easeOut(duration: 0.12), value: hovering)
            }
            .buttonStyle(PressDimStyle())
            // 工具栏里 onHover 收不到事件，用连续悬停
            .onContinuousHover { phase in
                if case .active = phase { hovering = true } else { hovering = false }
            }
            .disabled(recorder.isStarting)
            .help("开始录音（⌥⌘R，任何 app 里都能按）")
        }
    }
}

/// 按下时压暗一点（自绘按钮用）
struct PressDimStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? -0.08 : 0)
            .contentShape(Capsule())
    }
}

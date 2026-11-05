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
    @State private var showOnboarding = false
    @State private var diskFree: Int64?
    /// 转写稿有手动修改，等确认才重新转写
    @State private var pendingRetranscribe: Meeting?
    @AppStorage(Onboarding.completedKey) private var onboardingCompleted = false
    @State private var renameText = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .background(Theme.chrome)
                .navigationSplitViewColumnWidth(min: 250, ideal: 286, max: 380)
        } detail: {
            ZStack {
                if let m = meetings.first(where: { $0.id == processing.selectedMeetingID }) {
                    DetailView(meeting: m, env: env, recorder: recorder, processing: processing) { pendingDelete = [$0] }
                        // 录音结束时重建一次：播放器在录音中创建时文件还是空的，时长为 0
                        .id("\(m.id)|\(m.endedAt?.timeIntervalSince1970 ?? 0)")
                } else {
                    if meetings.isEmpty {
                        FirstMeetingView(recorder: recorder)
                    } else {
                        ContentUnavailableView {
                            Label("选择一场会议", systemImage: "waveform")
                        } description: {
                            Text("在左侧选择会议，查看转写稿、回放录音。")
                        }
                    }
                }
            }
            .background { Theme.canvas.ignoresSafeArea() }
            .toolbar {
                // 有会议时录音按钮由详情页放在工具栏最右；没有选中会议时放在这里
                // 一场会议都没有时，首屏中间已经有录音按钮
                if !meetings.isEmpty, !meetings.contains(where: { $0.id == processing.selectedMeetingID }) {
                    ToolbarItem(placement: .primaryAction) { RecordButton(recorder: recorder) }
                }
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        // 设计稿里工具栏和内容连成一片，不要分隔线
        .toolbarBackground(.hidden, for: .windowToolbar)
        // 标题留空而不是移除：移除后工具栏按钮会挤到左边
        .navigationTitle("")
        .task {
            do {
                var first = true
                for try await list in env.repository.observeAll() {
                    if first {
                        // 只在打开时判断一次：引导中途有了会议也不要突然关掉
                        first = false
                        if Onboarding.shouldShow(completed: onboardingCompleted, hasMeetings: !list.isEmpty) {
                            showOnboarding = true
                        } else {
                            onboardingCompleted = true
                        }
                    }
                    meetings = list
                    marked.formIntersection(list.map(\.id))
                    if processing.selectedMeetingID == nil { processing.selectedMeetingID = list.first?.id }
                    refreshUsage()
                }
            } catch {
                recorder.lastError = L("读取会议列表失败：\(error.localizedDescription)")
            }
        }
        .confirmationDialog("重新转写会丢掉手动修改", isPresented: Binding(get: { pendingRetranscribe != nil }, set: { if !$0 { pendingRetranscribe = nil } }),
                            titleVisibility: .visible) {
            Button("仍然重新转写", role: .destructive) {
                if let m = pendingRetranscribe { processing.enqueue(m.id) }
                pendingRetranscribe = nil
            }
        } message: {
            Text("这场会议的转写稿有你改过的句子，重新转写会生成新的转写稿，这些修改不会保留。")
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(env: env, live: recorder.live) {
                onboardingCompleted = true
                showOnboarding = false
            }
            .interactiveDismissDisabled()
        }
        .task(id: query) {
            // 转写内容搜索放后台，输入时不卡
            let q = query, transcripts = env.transcripts
            matched = await Task.detached { (try? transcripts.meetingIDs(matching: q)) ?? [] }.value
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { !pendingDelete.isEmpty }, set: { if !$0 { pendingDelete = [] } }),
                            titleVisibility: .visible) {
            Button(pendingDelete.count > 1 ? L("删除 \(pendingDelete.count) 场") : L("删除"), role: .destructive) { delete(pendingDelete) }
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
                Section(group.title) {
                    ForEach(items) { m in
                        let on = picked.contains(m.id)
                        MeetingRow(meeting: m, env: env, processing: processing)
                            .padding(.horizontal, 4)
                            .contentShape(Rectangle())
                            .onTapGesture { click(m.id) }
                            .listRowBackground(
                                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                                    .fill(on ? Color.accentColor.opacity(0.2) : .clear)
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
        .scrollContentBackground(.hidden)
        .searchable(text: $query, placement: .sidebar, prompt: "搜索会议和转写内容")
        .overlay {
            if !query.isEmpty && filtered.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .safeAreaInset(edge: .bottom) { storageCard }
    }

    /// 占用空间退到一行：数据始终看得见，但不抢内容的位置。磁盘快满时才变成提醒
    private var storageCard: some View {
        let warning = DiskSpace.level(free: diskFree) != .ok
        return HStack(spacing: 6) {
            if warning, let diskFree {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: .systemOrange))
                Text("磁盘只剩 \(bytes(diskFree))").foregroundStyle(Color(nsColor: .systemOrange))
            } else {
                Text("占用 \(bytes(usage.recordings + usage.models))").foregroundStyle(.tertiary)
            }
            Spacer()
            Button("管理") {
                UserDefaults.standard.set("storage", forKey: SettingsRoot.paneKey)
                openSettings()
            }
            .buttonStyle(.plain)
            .foregroundStyle(warning ? .primary : .secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .task {
            // 录音前就要看到提醒：每分钟看一次，占不了什么资源
            while !Task.isCancelled {
                diskFree = AppEnvironment.freeDiskSpace(paths: env.paths)
                try? await Task.sleep(for: .seconds(60))
            }
        }
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
            Button("精准转写") {
                if (try? env.transcripts.finalTranscriptHasEdits(meetingID: m.id)) == true {
                    pendingRetranscribe = m
                } else {
                    processing.enqueue(m.id)
                }
            }
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
        if pendingDelete.count == 1 { return L("删除「\(pendingDelete[0].title)」？将释放 \(bytes(size))") }
        return L("删除 \(pendingDelete.count) 场会议？将释放 \(bytes(size))")
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
        if !failed.isEmpty { recorder.lastError = L("删除失败\n") + failed.joined(separator: "\n") }
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
                Text(meeting.title).font(.system(size: 13, weight: .medium)).lineLimit(1)
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
        case .recording: StatusTag(text: L("录音中"), tint: Theme.record)
        case .processing: StatusTag(text: L("转写中 \(Int((processing.progress[meeting.id] ?? 0) * 100))%"), tint: Theme.me)
        case .failed: StatusTag(text: L("失败"), tint: .orange)
        case .interrupted: StatusTag(text: L("录音中断"), tint: .orange)
        case .pendingProcessing: StatusTag(text: L("待转写"), tint: .secondary)
        case .done: EmptyView()
        }
    }

    private var timeText: String {
        let start = Calendar.current.isDateInToday(meeting.startedAt) || Calendar.current.isDateInYesterday(meeting.startedAt)
            ? meeting.startedAt.formatted(.dateTime.hour().minute())
            : meeting.startedAt.formatted(.dateTime.month().day().hour().minute())
        guard let end = meeting.endedAt else { return start }
        return "\(start)  \(durationText(end.timeIntervalSince(meeting.startedAt)))"
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

/// 还没有会议时的首屏：告诉用户第一步做什么，以及录音和转写都发生在哪里
struct FirstMeetingView: View {
    @ObservedObject var recorder: RecordingController

    /// 示意用的两路声音：你一句，对方一句
    private static let sample: (mine: [Float], theirs: [Float]) = {
        let n = 72
        let wave = { (i: Int) in Float(0.45 + 0.55 * abs(sin(Double(i) * 0.55) * sin(Double(i) * 0.17 + 0.6))) }
        let mineOn = { (i: Int) in (i / 12) % 2 == 0 }
        return ((0..<n).map { mineOn($0) ? wave($0) : 0 }, (0..<n).map { mineOn($0) ? 0 : wave($0) })
    }()

    var body: some View {
        VStack(spacing: 22) {
            VoiceRibbon(mine: Self.sample.mine, theirs: Self.sample.theirs,
                        theirColors: Array(repeating: Theme.them, count: Self.sample.theirs.count),
                        marks: [], progress: 1, laneHeight: 26, showsPlayhead: false) { _ in }
                .frame(width: 360)
                .allowsHitTesting(false)
            VStack(spacing: 8) {
                Text("录下第一场会议").font(Theme.titleFont)
                Text("Moting 同时录你的麦克风和对方的声音，在这台 Mac 上转写，不需要联网。")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }
            RecordButton(recorder: recorder)
            Text("开会时在任何 app 里按 ⌥⌘R 也能开始").font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                Button(recorder.isStopping ? L("正在结束…") : L("结束")) { recorder.stop() }
                    .buttonStyle(AppButtonStyle(kind: .record))
                    .disabled(recorder.isStopping)
            }
            .padding(.horizontal, 6)
        default:
            // 工具栏会把标准按钮压成纯图标，这里自绘
            Button { recorder.start() } label: {
                HStack(spacing: 6) {
                    Circle().fill(.white).frame(width: 8, height: 8)
                    Text(recorder.isStarting ? L("正在启动…") : L("开始录音"))
                }
            }
            .buttonStyle(AppButtonStyle(kind: .record))
            .disabled(recorder.isStarting)
            .help("开始录音（⌥⌘R，任何 app 里都能按）")
        }
    }
}

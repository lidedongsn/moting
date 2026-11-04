import AppKit
import MotingCapture
import MotingCore
import MotingPlayback
import MotingStorage
import SwiftUI
import UniformTypeIdentifiers

/// 声纹带包络缓存：只放内存，不落盘（不在 app 目录之外产生文件）。
/// 按录音结束时间区分：录音中不缓存，录完（结束时间变了）自动重算
@MainActor
final class RibbonCache {
    static let shared = RibbonCache()
    private var store: [UUID: (endedAt: Date, mine: [Float], theirs: [Float])] = [:]

    func envelopes(for id: UUID, endedAt: Date?, paths: AppPaths) async -> (mine: [Float], theirs: [Float]) {
        if let endedAt, let hit = store[id], hit.endedAt == endedAt { return (hit.mine, hit.theirs) }
        let mic = paths.trackURL(id, .mic), sys = paths.trackURL(id, .system), bins = DetailView.bins
        let value = await Task.detached(priority: .userInitiated) {
            ((try? WaveformEnvelope.compute(mic, bins: bins)) ?? [],
             (try? WaveformEnvelope.compute(sys, bins: bins)) ?? [])
        }.value
        if let endedAt { store[id] = (endedAt, value.0, value.1) }
        return value
    }

    func invalidate(_ id: UUID) {
        store[id] = nil
    }
}

/// 会议详情：标题和参会人在上，转写稿和纪要并排，声纹带播放条常驻底部
struct DetailView: View {
    static let bins = 180

    let meeting: Meeting
    let env: AppEnvironment
    let onDelete: (Meeting) -> Void
    @ObservedObject var recorder: RecordingController
    @ObservedObject var processing: ProcessingModel

    private enum Tab: Hashable { case notes, transcript, marks }
    /// 内容区比这个窄时放不下并排的纪要，改成页签
    private static let sideBySideWidth: CGFloat = 780

    @StateObject private var player: MeetingPlayer
    @State private var tab: Tab = .transcript
    @State private var inspectorTab: Tab = .notes
    @AppStorage("detail.showInspector") private var showInspector = true
    @State private var turns: [TranscriptTurn] = []
    @State private var turnTexts: [UUID: TurnText] = [:]
    @State private var title: String
    @State private var editingTitle = false
    @FocusState private var titleFocused: Bool
    @State private var segments: [TranscriptSegment] = []
    @State private var allSegmentsForColors: [TranscriptSegment] = []
    @State private var marks: [Mark] = []
    @State private var transcriptKind: TranscriptKind?
    @State private var hasFinal = false
    @State private var hasDraft = false
    @State private var showDraft = false
    @AppStorage("player.rate") private var playbackRate = 1.0
    @AppStorage("player.skipSilence") private var skipSilence = false
    @State private var job: Job?
    @State private var names: [String: String] = [:]
    @State private var renamingSpeaker: String?
    @State private var speakerNameText = ""
    @State private var mine: [Float] = []
    @State private var theirs: [Float] = []

    init(meeting: Meeting, env: AppEnvironment, recorder: RecordingController, processing: ProcessingModel,
         onDelete: @escaping (Meeting) -> Void) {
        self.meeting = meeting
        self.env = env
        self.recorder = recorder
        self.processing = processing
        self.onDelete = onDelete
        _title = State(initialValue: meeting.title)
        _player = StateObject(wrappedValue: MeetingPlayer(urls: AudioChannel.allCases.map { env.paths.trackURL(meeting.id, $0) }))
    }

    // 说话人编号与声纹带下半的颜色：只在转写稿变化时算一次（播放时每 0.1 秒刷新，不能每次重算）
    @State private var indices: [SpeakerKey: Int] = [:]
    @State private var theirColors: [Color] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                titleRow
                metaRow.padding(.top, 8)
                processingBanner
            }
            .padding(.horizontal, 32)
            .padding(.top, 4)
            .padding(.bottom, 16)
            Rectangle().fill(Theme.hairline).frame(height: 0.5)
            GeometryReader { geo in
                if geo.size.width >= Self.sideBySideWidth {
                    HStack(spacing: 0) {
                        transcriptColumn
                        if showInspector {
                            Rectangle().fill(Theme.hairline).frame(width: 0.5)
                            inspector.frame(width: min(380, geo.size.width * 0.4))
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        tabBar.padding(.horizontal, 24).padding(.vertical, 10)
                        Group {
                            switch tab {
                            case .transcript: transcriptColumn
                            case .marks: marksList
                            case .notes: notes
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
            }
            transport
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .toolbar { detailToolbar }
        .task(id: meeting.status) { load() }
        .task(id: meeting.id) {
            let e = await RibbonCache.shared.envelopes(for: meeting.id, endedAt: meeting.endedAt, paths: env.paths)
            mine = e.mine
            theirs = e.theirs
        }
        .task(id: meeting.id) {
            do {
                for try await j in env.jobs.observe(meetingID: meeting.id) {
                    let changed = j?.status != job?.status
                    job = j
                    if changed { load() }
                }
            } catch {}
        }
        .onChange(of: showDraft) { _, _ in load() }
        .onChange(of: meeting.title) { _, t in if !editingTitle { title = t } }
        .alert("说话人改名", isPresented: Binding(get: { renamingSpeaker != nil }, set: { if !$0 { renamingSpeaker = nil } })) {
            TextField("名字（留空恢复默认）", text: $speakerNameText)
            Button("保存") {
                if let label = renamingSpeaker {
                    try? env.speakers.setName(meetingID: meeting.id, label: label, name: speakerNameText)
                    names = (try? env.speakers.names(meetingID: meeting.id)) ?? [:]
                }
                renamingSpeaker = nil
            }
            Button("取消", role: .cancel) { renamingSpeaker = nil }
        } message: {
            Text(renamingSpeaker.map { L("把「\($0)」改成真实姓名，转写稿和导出会同步更新。") } ?? "")
        }
        .onDisappear { player.close() }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            // 录音按钮在「更多」左边，「更多」照 macOS 习惯放最右
            RecordButton(recorder: recorder)
            Menu {
                Button("导出为 Markdown", action: exportMarkdown)
                Button(hasFinal ? L("重新转写") : L("精准转写")) { processing.enqueue(meeting.id) }
                    .disabled(meeting.status == .recording || job?.status == .running || job?.status == .queued)
                Button("在 Finder 中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([env.paths.meetingDirectory(meeting.id)])
                }
                Divider()
                Button("删除会议…", role: .destructive) { onDelete(meeting) }
                    .disabled(meeting.status == .recording)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(ToolbarPillStyle(iconOnly: true))
            .help("更多")
            Button { showInspector.toggle() } label: { Image(systemName: "sidebar.right") }
                .buttonStyle(ToolbarPillStyle(iconOnly: true))
                .help(showInspector ? L("隐藏纪要") : L("显示纪要"))
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }

    // MARK: - 头部

    @ViewBuilder
    private var titleRow: some View {
        if editingTitle {
            // 系统圆角输入框高度固定，放大字会被裁掉：用无边框的，字号和位置跟显示时一样
            TextField("会议标题", text: $title)
                .textFieldStyle(.plain)
                .font(Theme.titleFont)
                .lineLimit(1)
                .padding(.vertical, 2)
                .padding(.horizontal, 8)
                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
                .padding(.vertical, -2)
                .padding(.horizontal, -8)
                .focused($titleFocused)
                .onSubmit(commitTitle)
                .onExitCommand(perform: cancelTitle)
                .onChange(of: titleFocused) { _, f in if !f { commitTitle() } }
                .onAppear { titleFocused = true }
        } else {
            HStack(spacing: 8) {
                Text(title)
                    .font(Theme.titleFont)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { editingTitle = true }
                Button { editingTitle = true } label: { Image(systemName: "pencil").foregroundStyle(.tertiary) }
                    .buttonStyle(.borderless)
                    .help("重命名")
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 18) {
            Text(timeRange)
            HStack(spacing: 12) {
                ForEach(people, id: \.key) { p in
                    HStack(spacing: 6) {
                        SpeakerAvatar(name: p.name, color: Theme.speaker(p.index), size: 20)
                        Text(p.name).lineLimit(1).fixedSize()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if case .other(let label) = p.key, label != SpeakerLabel.other { beginRename(label) } }
                    .help(p.key == .me || p.key == .other(SpeakerLabel.other) ? "" : "点击改名")
                }
            }
            Spacer()
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }

    private struct Person { let key: SpeakerKey; let index: Int; let name: String }

    private var people: [Person] {
        indices.sorted { $0.value < $1.value }.map { key, i in
            let name: String
            switch key {
            case .me: name = L("我")
            case .other(let label): name = names[label] ?? SpeakerLabel.display(label)
            }
            return Person(key: key, index: i, name: name)
        }
        .filter { $0.key != .me || allSegmentsForColors.contains { $0.channel == .mic } || allSegmentsForColors.isEmpty }
    }

    private var timeRange: String {
        let day = meeting.startedAt.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute())
        guard let end = meeting.endedAt else { return day }
        return "\(day)–\(end.formatted(.dateTime.hour().minute()))  \(durationText(end.timeIntervalSince(meeting.startedAt)))"
    }

    // MARK: - 底部播放条

    private var transport: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = player.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 14) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.canvas)
                        .frame(width: 32, height: 32)
                        .background(.primary, in: Circle())
                }
                .buttonStyle(HoverGrowStyle())
                .keyboardShortcut(editingTitle ? nil : KeyboardShortcut(.space, modifiers: []))
                .disabled(player.duration == 0)
                Text(clock(player.currentTime)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                VoiceRibbon(mine: mine, theirs: theirs, theirColors: theirColors,
                            marks: player.duration > 0 ? marks.map { $0.at / player.duration } : [],
                            progress: player.duration > 0 ? player.currentTime / player.duration : 0) { f in
                    player.seek(to: f * player.duration)
                }
                Text(clock(player.duration)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                playbackOptions
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Theme.chrome)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    /// 倍速（点一下换一档）与跳过静音，记住上次的选择
    private var playbackOptions: some View {
        HStack(spacing: 10) {
            Button {
                let rates: [Double] = [1, 1.25, 1.5, 2]
                playbackRate = rates[((rates.firstIndex(of: playbackRate) ?? 0) + 1) % rates.count]
            } label: {
                Text(playbackRate == 1 ? "1×" : "\(playbackRate.formatted(.number.precision(.fractionLength(0...2))))×")
                    .monospacedDigit()
                    .foregroundStyle(playbackRate == 1 ? Color.secondary : Theme.me)
            }
            .help("播放速度（点击切换 1× / 1.25× / 1.5× / 2×）")
            Button { skipSilence.toggle() } label: {
                Image(systemName: "forward.end.alt").foregroundStyle(skipSilence ? Theme.me : Color.secondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .help(skipSilence ? L("已开启：长于半秒的静音只停半秒") : L("开启后跳过长时间没人说话的部分"))
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .medium))
        .onAppear { player.rate = Float(playbackRate); player.skipSilence = skipSilence }
        .onChange(of: playbackRate) { _, v in player.rate = Float(v) }
        .onChange(of: skipSilence) { _, v in player.skipSilence = v }
    }

    /// 下半每根柱子的颜色：该时刻在说话的对方说话人
    private func computeTheirColors() -> [Color] {
        let system = allSegmentsForColors.filter { $0.channel == .system }
        let idx = indices
        return SpeakingTimeline.bins(system, duration: player.duration, count: Self.bins).map { key in
            key.map { Theme.speaker($0, in: idx) } ?? Theme.them
        }
    }

    // MARK: - 处理状态

    @ViewBuilder
    private var processingBanner: some View {
        if let job, let content = bannerContent(job) {
            HStack(spacing: 10) { content }
                .font(.system(size: 13))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.me.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.me.opacity(0.25), lineWidth: 0.5))
                .padding(.top, 12)
        }
    }

    private func bannerContent(_ job: Job) -> AnyView? {
        let p = processing.progress[meeting.id] ?? job.progress
        switch job.status {
        case .queued, .running:
            return AnyView(Group {
                ProgressRing(progress: p)
                Text("正在精准转写 \(Int(p * 100))%").fontWeight(.semibold)
                Text("完成后会替换实时草稿，并通知你。").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("暂停") { processing.pause(meeting.id) }.buttonStyle(PaneButtonStyle())
            })
        case .paused:
            return AnyView(Group {
                ProgressRing(progress: job.progress, dimmed: true)
                Text("精准转写已暂停 \(Int(job.progress * 100))%").fontWeight(.semibold)
                Text("已完成的部分会保留，继续时接着处理。").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("继续") { processing.resume(meeting.id) }.buttonStyle(PaneButtonStyle(kind: .primary))
            })
        case .waitingForPower:
            return AnyView(Group {
                Image(systemName: "powerplug.fill").foregroundStyle(Theme.me).frame(width: 20)
                Text("正在使用电池").fontWeight(.semibold)
                Text("接通电源后自动精准转写。").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("现在处理") { processing.processNow(meeting.id) }.buttonStyle(PaneButtonStyle())
            })
        case .failed:
            return AnyView(Group {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(width: 20)
                Text("精准转写失败：\(job.error ?? L("未知错误"))").lineLimit(2)
                Spacer(minLength: 0)
                Button("重试") { processing.enqueue(meeting.id) }.buttonStyle(PaneButtonStyle())
            })
        case .done:
            if job.filterOutcome == "fellBack" {
                return AnyView(Group {
                    Image(systemName: "info.circle").foregroundStyle(Theme.me).frame(width: 20)
                    Text("麦克风一路与你的声纹匹配度偏低，这次没有过滤旁人声音。可以在设置里重新登记声纹。")
                    Spacer(minLength: 0)
                })
            }
            return nil
        }
    }

    // MARK: - 页签

    /// 窄窗口下的页签
    private var tabBar: some View {
        HStack {
            PillTabs(selection: $tab, items: [
                .init(value: .transcript, title: L("转写稿")),
                .init(value: .notes, title: L("纪要")),
                .init(value: .marks, title: L("标记"), badge: marks.isEmpty ? nil : "\(marks.count)"),
            ], size: .small)
            Spacer()
        }
    }

    // MARK: - 右栏

    private var notes: some View {
        SummaryView(meetingID: meeting.id, model: processing.summary, hasTranscript: !segments.isEmpty)
    }

    private var inspector: some View {
        VStack(spacing: 0) {
            HStack {
                PillTabs(selection: $inspectorTab, items: [
                    .init(value: .notes, title: L("纪要")),
                    .init(value: .marks, title: L("标记"), badge: marks.isEmpty ? nil : "\(marks.count)"),
                ], size: .small)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Group {
                if inspectorTab == .marks { marksList } else { notes }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(Theme.chrome.opacity(0.5))
    }

    // MARK: - 转写稿

    private var transcriptColumn: some View {
        VStack(spacing: 0) {
            if hasFinal && hasDraft {
                HStack {
                    Spacer()
                    PillTabs(selection: $showDraft, items: [
                        .init(value: false, title: L("精准")),
                        .init(value: true, title: L("实时草稿")),
                    ], size: .small)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            } else if transcriptKind == .draft {
                HStack {
                    Spacer()
                    Text("实时字幕草稿").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
            }
            transcript
        }
    }

    @ViewBuilder
    private var transcript: some View {
        if segments.isEmpty {
            ContentUnavailableView {
                Label("暂无转写内容", systemImage: "text.bubble")
            } description: {
                Text("用离线大模型识别整段录音，生成带说话人的转写稿。")
            } actions: {
                Button("精准转写") { processing.enqueue(meeting.id) }
                    .disabled(meeting.status == .recording)
            }
        } else {
            let t = player.currentTime
            let currentTurn = t > 0 ? TranscriptTurns.index(in: turns, at: t).map { turns[$0].id } : nil
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(turns) { turn in
                            let current = turn.id == currentTurn
                            TurnView(turn: turn, turnText: turnTexts[turn.id] ?? TurnText(turn),
                                     name: speakerName(turn), color: Theme.speaker(turn.speaker, in: indices),
                                     currentSegment: current ? currentSegmentID : nil, isCurrent: current, isPlaying: player.isPlaying,
                                     hasMark: marks.contains { $0.at >= turn.start && $0.at <= turn.end + 1 },
                                     onRename: renameAction(turn),
                                     onSeek: { segment in
                                         player.seek(to: TranscriptTurns.playbackStart(of: segment, kind: transcriptKind))
                                         player.play()
                                     },
                                     onTogglePlay: { player.toggle() })
                            .id(turn.id)
                        }
                    }
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: currentTurn) { _, id in
                    if player.isPlaying, let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
    }

    private func speakerName(_ turn: TranscriptTurn) -> String {
        MarkdownExporter.displayName(turn.segments[0], names)
    }

    private func renameAction(_ turn: TranscriptTurn) -> (() -> Void)? {
        turn.segments[0].speakerLabel.map { label in { beginRename(label) } }
    }

    /// segments 按开始时间排好序：二分找最后一个开始时间不晚于当前播放位置的句子
    private var currentSegmentID: UUID? {
        let t = player.currentTime
        var lo = 0, hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 ? segments[lo - 1].id : nil
    }

    // MARK: - 标记

    @ViewBuilder
    private var marksList: some View {
        if marks.isEmpty {
            ContentUnavailableView("没有标记", systemImage: "star",
                                   description: Text("开会时点悬浮窗或菜单栏里的 ★，会在这里留下时间点。"))
        } else {
            List(marks) { m in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Image(systemName: "star.fill").foregroundStyle(Theme.mark).font(.system(size: 11))
                    Text(clock(m.at)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    Text(context(for: m) ?? L("（这段时间没有转写内容）"))
                        .foregroundStyle(context(for: m) == nil ? .tertiary : .primary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    if tab == .marks { tab = .transcript }
                    player.seek(to: max(0, m.at - 5))
                    player.play()
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    /// 标记附近的原话：标记前最近开始的一句
    private func context(for m: Mark) -> String? {
        segments.last { $0.start <= m.at + 1 }.map { "\(MarkdownExporter.displayName($0, names))：\($0.text)" }
    }

    // MARK: - 数据与操作

    private func load() {
        marks = (try? env.repository.marks(meeting.id)) ?? []
        names = (try? env.speakers.names(meetingID: meeting.id)) ?? [:]
        let final = try? env.transcripts.latestVersion(meetingID: meeting.id, kind: .final)
        let draft = try? env.transcripts.latestVersion(meetingID: meeting.id, kind: .draft)
        hasFinal = final != nil
        hasDraft = draft != nil
        let chosen: (UUID, TranscriptKind)? = {
            if let final, !showDraft { return (final, .final) }
            if let draft { return (draft, .draft) }
            return final.map { ($0, .final) }
        }()
        if let (v, kind) = chosen {
            segments = (try? env.transcripts.segments(versionID: v)) ?? []
            transcriptKind = kind
        } else {
            segments = []
            transcriptKind = nil
        }
        turns = TranscriptTurns.group(segments)
        turnTexts = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, TurnText($0)) })
        // 颜色以精准稿（有说话人分离）为准，保证各处一致
        allSegmentsForColors = final.flatMap { try? env.transcripts.segments(versionID: $0) } ?? segments
        indices = SpeakerPalette.indices(for: allSegmentsForColors)
        theirColors = computeTheirColors()
    }

    private func beginRename(_ label: String) {
        speakerNameText = names[label] ?? ""
        renamingSpeaker = label
    }

    private func commitTitle() {
        guard editingTitle else { return }
        editingTitle = false
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { title = meeting.title; return }
        title = t
        do { try env.repository.rename(meeting.id, to: t) } catch { recorder.lastError = L("改名失败：\(error.localizedDescription)") }
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
        let md = MarkdownExporter.export(meeting: m, segments: segments, marks: marks, names: names,
                                         summary: processing.summary.stored(meeting.id)?.summary)
        do { try md.write(to: url, atomically: true, encoding: .utf8) } catch { recorder.lastError = L("导出失败：\(error.localizedDescription)") }
    }
}

/// 说话人头像：彩色圆底加名字的一个字；"说话人 2"这样的显示编号
struct SpeakerAvatar: View {
    let name: String
    let color: Color
    var size: CGFloat = 28

    private var glyph: String {
        if let last = name.last, last.isNumber { return String(last) }
        return name.first.map { String($0).uppercased() } ?? ""
    }

    var body: some View {
        Text(glyph)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.16), in: Circle())
    }
}

/// 转写稿的一段发言：头像、名字、时间，下面是连续的几句话，点哪句从哪句开始播。
/// 当前句用强调色，当前段带淡底；播放时其余文字变暗，暂停时恢复，方便阅读
struct TurnView: View {
    let turn: TranscriptTurn
    let turnText: TurnText
    let name: String
    let color: Color
    let currentSegment: UUID?
    let isCurrent: Bool
    let isPlaying: Bool
    let hasMark: Bool
    let onRename: (() -> Void)?
    let onSeek: (TranscriptSegment) -> Void
    let onTogglePlay: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SpeakerAvatar(name: name, color: color)
                .onTapGesture { onRename?() }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .onTapGesture { onRename?() }
                        .help(onRename == nil ? name : L("\(name)（点击改名）"))
                    Text(clock(turn.start)).font(.system(size: 12)).monospacedDigit().foregroundStyle(.tertiary)
                    if hasMark { Text("★").font(.system(size: 11)).foregroundStyle(Theme.mark) }
                }
                SentenceText(turnText: turnText, currentSegment: currentSegment, isPlaying: isPlaying,
                             onSeek: onSeek, onTogglePlay: onTogglePlay)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(isCurrent ? Color.accentColor.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }
}

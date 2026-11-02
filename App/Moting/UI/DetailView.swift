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

/// 会议详情：标题、参会人、声纹带播放器、处理状态、纪要 / 转写稿 / 标记
struct DetailView: View {
    static let bins = 180

    let meeting: Meeting
    let env: AppEnvironment
    let onDelete: (Meeting) -> Void
    @ObservedObject var recorder: RecordingController
    @ObservedObject var processing: ProcessingModel

    private enum Tab: Hashable { case notes, transcript, marks }

    @StateObject private var player: MeetingPlayer
    @State private var tab: Tab = .transcript
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
                metaRow.padding(.top, 6)
                ribbonCard.padding(.top, 18)
                if let error = player.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).padding(.top, 6)
                }
                processingBanner
                tabBar.padding(.top, 16)
            }
            .padding(.horizontal, 28)
            .padding(.top, 8)
            Group {
                switch tab {
                case .transcript: transcript
                case .marks: marksList
                case .notes: SummaryView(meetingID: meeting.id, model: processing.summary, hasTranscript: !segments.isEmpty)
                }
            }
            // 内容区撑满剩余高度：切换页签时头部和播放器位置不动
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, 8)
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
            Text(renamingSpeaker.map { "把「\($0)」改成真实姓名，转写稿和导出会同步更新。" } ?? "")
        }
        .onDisappear { player.close() }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button("导出", systemImage: "square.and.arrow.down", action: exportMarkdown)
                .buttonStyle(ToolbarPillStyle())
                .help("导出为 Markdown")
            Button(hasFinal ? "重新转写" : "精准转写", systemImage: "arrow.clockwise") { processing.enqueue(meeting.id) }
                .buttonStyle(ToolbarPillStyle())
                .disabled(meeting.status == .recording || job?.status == .running || job?.status == .queued)
                .help("用离线大模型对整段录音重新识别，生成正式稿（草稿保留）")
            Menu {
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
            // 录音按钮排在最右（设计稿）
            RecordButton(recorder: recorder)
        }
    }

    // MARK: - 头部

    @ViewBuilder
    private var titleRow: some View {
        if editingTitle {
            TextField("会议标题", text: $title)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 24, weight: .bold))
                .focused($titleFocused)
                .onSubmit(commitTitle)
                .onExitCommand(perform: cancelTitle)
                .onChange(of: titleFocused) { _, f in if !f { commitTitle() } }
                .onAppear { titleFocused = true }
        } else {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.3)
                    .lineLimit(1)
                    .onTapGesture(count: 2) { editingTitle = true }
                Button { editingTitle = true } label: { Image(systemName: "pencil").foregroundStyle(.tertiary) }
                    .buttonStyle(.borderless)
                    .help("重命名")
            }
        }
    }

    private var metaRow: some View {
        HStack(spacing: 16) {
            Text(timeRange)
            HStack(spacing: 10) {
                ForEach(people, id: \.key) { p in
                    HStack(spacing: 5) {
                        Circle().fill(Theme.speaker(p.index)).frame(width: 8, height: 8)
                        Text(p.name)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { if case .other(let label) = p.key, label != "对方" { beginRename(label) } }
                    .help(p.key == .me || p.key == .other("对方") ? "" : "点击改名")
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
            case .me: name = "我"
            case .other(let label): name = names[label] ?? label
            }
            return Person(key: key, index: i, name: name)
        }
        .filter { $0.key != .me || allSegmentsForColors.contains { $0.channel == .mic } || allSegmentsForColors.isEmpty }
    }

    private var timeRange: String {
        let day = meeting.startedAt.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute())
        guard let end = meeting.endedAt else { return day }
        return "\(day)–\(end.formatted(.dateTime.hour().minute())) · \(durationText(end.timeIntervalSince(meeting.startedAt)))"
    }

    // MARK: - 声纹带播放器

    private var ribbonCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 34, height: 34)
                        .background(.primary, in: Circle())
                }
                .buttonStyle(HoverGrowStyle())
                .keyboardShortcut(editingTitle ? nil : KeyboardShortcut(.space, modifiers: []))
                .disabled(player.duration == 0)
                Text(clock(player.currentTime)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                Text("/ \(clock(player.duration))").font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                playbackOptions
            }
            VoiceRibbon(mine: mine, theirs: theirs, theirColors: theirColors,
                        marks: player.duration > 0 ? marks.map { $0.at / player.duration } : [],
                        progress: player.duration > 0 ? player.currentTime / player.duration : 0) { f in
                player.seek(to: f * player.duration)
            }
            HStack {
                Text("我 · 上")
                Spacer()
                Text("对方 · 下（按说话人着色）")
            }
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glassCard(radius: 14, material: .thinMaterial)
    }

    /// 倍速（点一下换一档）与跳过静音，记住上次的选择
    private var playbackOptions: some View {
        HStack(spacing: 6) {
            Button {
                let rates: [Double] = [1, 1.25, 1.5, 2]
                playbackRate = rates[((rates.firstIndex(of: playbackRate) ?? 0) + 1) % rates.count]
            } label: {
                Text(playbackRate == 1 ? "1×" : "\(playbackRate.formatted(.number.precision(.fractionLength(0...2))))×")
                    .monospacedDigit()
                    .foregroundStyle(playbackRate == 1 ? Color.secondary : Theme.me)
            }
            .help("播放速度（点击切换 1× / 1.25× / 1.5× / 2×）")
            Text("·").foregroundStyle(.tertiary)
            Button { skipSilence.toggle() } label: {
                Text("跳过静音").foregroundStyle(skipSilence ? Theme.me : Color.secondary)
            }
            .help(skipSilence ? "已开启：长于半秒的静音只停半秒" : "开启后跳过长时间没人说话的部分")
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
                .background(Theme.me.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.me.opacity(0.25), lineWidth: 0.5))
                .padding(.top, 14)
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
                Text("精准转写失败：\(job.error ?? "未知错误")").lineLimit(2)
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

    private var tabBar: some View {
        HStack {
            PillTabs(selection: $tab, items: [
                .init(value: .notes, title: "纪要"),
                .init(value: .transcript, title: "转写稿"),
                .init(value: .marks, title: "标记", badge: marks.isEmpty ? nil : "\(marks.count)"),
            ])
            Spacer()
            if tab == .transcript {
                if hasFinal && hasDraft {
                    HStack(spacing: 8) {
                        Text("版本").font(.system(size: 12)).foregroundStyle(.tertiary)
                        PillTabs(selection: $showDraft, items: [
                            .init(value: false, title: "精准"),
                            .init(value: true, title: "实时草稿"),
                        ], size: .small)
                    }
                } else if let kind = transcriptKind {
                    Text(kind == .draft ? "实时字幕草稿" : "精准转写").font(.system(size: 12)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - 转写稿

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
            // 当前句每次刷新只找一次，不在每一行里各找一遍
            let current = player.currentTime > 0 ? currentSegmentID : nil
            ScrollViewReader { proxy in
                List(segments) { s in
                    TranscriptLine(segment: s, name: MarkdownExporter.speakerName(s, names),
                                   color: Theme.speaker(s.speakerKey, in: indices),
                                   isCurrent: s.id == current,
                                   hasMark: marks.contains { $0.at >= s.start && $0.at <= s.end + 1 },
                                   onRename: s.speakerLabel.map { label in { beginRename(label) } })
                        .id(s.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 1, leading: 20, bottom: 1, trailing: 20))
                        .contentShape(Rectangle())
                        .onTapGesture {
                            // 实时识别的句首普遍偏晚，提前 1 秒播放，避免切掉第一个字
                            player.seek(to: max(0, s.start - 1))
                            player.play()
                        }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .onChange(of: currentSegmentID) { _, id in
                    if player.isPlaying, let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
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
                    Text(context(for: m) ?? "（这段时间没有转写内容）")
                        .foregroundStyle(context(for: m) == nil ? .tertiary : .primary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .onTapGesture {
                    tab = .transcript
                    player.seek(to: max(0, m.at - 5))
                    player.play()
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 28, bottom: 0, trailing: 28))
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    /// 标记附近的原话：标记前最近开始的一句
    private func context(for m: Mark) -> String? {
        segments.last { $0.start <= m.at + 1 }.map { "\(MarkdownExporter.speakerName($0, names))：\($0.text)" }
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
        do { try env.repository.rename(meeting.id, to: t) } catch { recorder.lastError = "改名失败：\(error.localizedDescription)" }
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
        do { try md.write(to: url, atomically: true, encoding: .utf8) } catch { recorder.lastError = "导出失败：\(error.localizedDescription)" }
    }
}

/// 转写稿的一行：时间、说话人色条与名字、文字
struct TranscriptLine: View {
    let segment: TranscriptSegment
    let name: String
    let color: Color
    let isCurrent: Bool
    let hasMark: Bool
    let onRename: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(clock(segment.start))
                .font(.system(size: 12)).monospacedDigit().foregroundStyle(.tertiary)
                .frame(width: 52, alignment: .leading)
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 14)
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            }
            // 固定宽度：各行正文左边对齐
            .frame(width: 92, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onRename?() }
            .help(onRename == nil ? name : "\(name)（点击改名）")
            (Text(segment.text) + (hasMark ? Text("  ★").foregroundColor(Theme.mark) : Text("")))
                .font(.system(size: 14.5))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isCurrent ? Theme.me.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isCurrent ? Theme.me.opacity(0.3) : .clear, lineWidth: 0.5))
    }
}

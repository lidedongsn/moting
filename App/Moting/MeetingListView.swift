import AppKit
import MotingCore
import MotingStorage
import SwiftUI

struct MeetingListView: View {
    let env: AppEnvironment
    @ObservedObject var recorder: RecordingController
    @State private var meetings: [Meeting] = []
    @State private var selection: Meeting.ID?
    @State private var usage: Int64 = 0
    @State private var modelsUsage: Int64 = 0
    @State private var pendingDelete: Meeting?

    var body: some View {
        VStack(spacing: 0) {
            RecorderBar(recorder: recorder)
            Divider()
            NavigationSplitView {
                list
                    .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
            } detail: {
                if let m = meetings.first(where: { $0.id == selection }) {
                    MeetingDetailView(meeting: m, env: env, recorder: recorder) { pendingDelete = $0 }
                        .id(m.id)
                } else {
                    ContentUnavailableView("选择一场会议", systemImage: "waveform",
                                           description: Text("在左侧选择会议，查看转写稿、回放录音"))
                }
            }
            Divider()
            storageFooter
        }
        .frame(minWidth: 820, minHeight: 520)
        .task {
            do {
                for try await list in env.repository.observeAll() {
                    meetings = list
                    if selection == nil { selection = list.first?.id }
                    usage = env.paths.meetingsDiskUsage()
                    modelsUsage = env.paths.modelsDiskUsage()
                }
            } catch {
                recorder.lastError = "读取会议列表失败：\(error.localizedDescription)"
            }
        }
    }

    private var list: some View {
        List(meetings, selection: $selection) { m in
            VStack(alignment: .leading, spacing: 3) {
                Text(m.title).font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(m.startedAt.formatted(date: .abbreviated, time: .shortened))
                    Text(m.endedAt.map { $0.timeIntervalSince(m.startedAt).clockText } ?? "—").monospacedDigit()
                    Spacer()
                    Text(m.status.displayName)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
            .tag(m.id)
            .contextMenu {
                Button("在 Finder 中显示") { reveal(env.paths.meetingDirectory(m.id)) }
                Divider()
                Button("删除会议…", role: .destructive) { pendingDelete = m }
                    .disabled(m.status == .recording)
            }
        }
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { pendingDelete != nil },
                                                             set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let m = pendingDelete { delete(m) }
            }
        } message: {
            Text("录音文件和会议记录会被永久删除，无法恢复。")
        }
        .overlay {
            if meetings.isEmpty {
                ContentUnavailableView("还没有会议记录", systemImage: "waveform",
                                       description: Text("从菜单栏图标开始录音"))
            }
        }
    }
}

private extension MeetingListView {
    var paths: AppPaths { env.paths }

    var storageFooter: some View {
        HStack(spacing: 8) {
            Image(systemName: "internaldrive").foregroundStyle(.secondary)
            Text("录音 \(Self.bytes(usage)) · 模型 \(Self.bytes(modelsUsage))")
            Text(paths.meetingsRoot.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button("在 Finder 中显示") {
                try? FileManager.default.createDirectory(at: paths.meetingsRoot, withIntermediateDirectories: true)
                reveal(paths.meetingsRoot)
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    var deleteTitle: String {
        guard let m = pendingDelete else { return "" }
        return "删除「\(m.title)」？将释放 \(Self.bytes(paths.diskUsage(of: m.id)))"
    }

    func delete(_ m: Meeting) {
        do {
            // 先删文件再删记录：文件删除失败时记录还在，用户能再试
            let dir = paths.meetingDirectory(m.id)
            if FileManager.default.fileExists(atPath: dir.path) {
                try FileManager.default.removeItem(at: dir)
            }
            if selection == m.id { selection = nil }
            try env.repository.delete(m.id)
        } catch {
            recorder.lastError = "删除失败：\(error.localizedDescription)"
        }
        pendingDelete = nil
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
}

extension MeetingStatus {
    var displayName: String {
        switch self {
        case .recording: "录音中"
        case .pendingProcessing: "待处理"
        case .interrupted: "录音中断"
        case .processing: "处理中"
        case .done: "完成"
        case .failed: "失败"
        }
    }
}

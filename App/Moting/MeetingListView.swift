import MotingCore
import MotingStorage
import SwiftUI

struct MeetingListView: View {
    let repository: MeetingRepository
    @ObservedObject var recorder: RecordingController
    @State private var meetings: [Meeting] = []

    var body: some View {
        VStack(spacing: 0) {
            RecorderBar(recorder: recorder)
            Divider()
            list
        }
        .frame(minWidth: 560, minHeight: 360)
        .task {
            do {
                for try await list in repository.observeAll() { meetings = list }
            } catch {
                recorder.lastError = "读取会议列表失败：\(error.localizedDescription)"
            }
        }
    }

    private var list: some View {
        List(meetings) { m in
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.title).font(.headline)
                    Text(m.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(m.endedAt.map { $0.timeIntervalSince(m.startedAt).clockText } ?? "—")
                    .monospacedDigit().foregroundStyle(.secondary)
                Text(m.status.displayName)
                    .font(.caption)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
            }
            .padding(.vertical, 2)
        }
        .overlay {
            if meetings.isEmpty {
                ContentUnavailableView("还没有会议记录", systemImage: "waveform",
                                       description: Text("从菜单栏图标开始录音"))
            }
        }
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

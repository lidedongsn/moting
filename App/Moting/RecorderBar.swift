import MotingCore
import SwiftUI

/// 主窗口顶部的录音控制条。菜单栏图标可能被刘海挡住，这里提供同样的操作
struct RecorderBar: View {
    @ObservedObject var recorder: RecordingController

    var body: some View {
        HStack(spacing: 12) {
            switch recorder.state {
            case .recording, .paused:
                Circle()
                    .fill(recorder.state == .paused ? Color.orange : Color.red)
                    .frame(width: 10, height: 10)
                Text(recorder.elapsed.clockText).monospacedDigit().font(.title3)
                LevelView(label: "我", level: recorder.levels[.mic] ?? 0)
                LevelView(label: "对方", level: recorder.levels[.system] ?? 0)
                Spacer()
                if recorder.state == .paused {
                    Button("继续", systemImage: "play.fill") { recorder.resume() }
                } else {
                    Button("暂停", systemImage: "pause.fill") { recorder.pause() }
                }
                Button("标记", systemImage: "star.fill") { recorder.mark() }
                Button(recorder.isStopping ? "正在结束…" : "结束", systemImage: "stop.fill") { recorder.stop() }
                    .tint(.red)
                    .disabled(recorder.isStopping)
            default:
                Text("未在录音").foregroundStyle(.secondary)
                Spacer()
                Button(recorder.isStarting ? "正在启动…" : "开始录音", systemImage: "record.circle") { recorder.start() }
                    .disabled(recorder.isStarting)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct LevelView: View {
    let label: String
    let level: Float

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(.green)
                        .frame(width: geo.size.width * CGFloat(min(1, (level * 50).squareRoot() / 3)))
                }
            }
            .frame(width: 60, height: 6)
        }
    }
}

import MotingCore
import SwiftUI

struct MenuBarContent: View {
    @ObservedObject var recorder: RecordingController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch recorder.state {
        case .recording, .paused:
            Text("\(recorder.state == .paused ? "已暂停" : "录音中") \(recorder.elapsed.clockText)")
            Text("我 \(levelText(.mic))  ·  对方 \(levelText(.system))")
            Divider()
            if recorder.state == .paused {
                Button("继续") { recorder.resume() }
            } else {
                Button("暂停") { recorder.pause() }
            }
            Button("★ 标记重点") { recorder.mark() }
            Button("结束录音") { recorder.stop() }
        default:
            Button(recorder.isStarting ? "正在启动…" : "开始录音") { recorder.start() }
                .disabled(recorder.isStarting)
        }
        Divider()
        Button("打开 Moting") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("退出") {
            recorder.stop()
            NSApp.terminate(nil)
        }
    }

    private func levelText(_ ch: AudioChannel) -> String {
        let v = recorder.levels[ch] ?? 0
        // 粗略转成 0–5 格
        let bars = min(5, Int((v * 50).squareRoot() * 2))
        return String(repeating: "▮", count: bars) + String(repeating: "▯", count: 5 - bars)
    }
}

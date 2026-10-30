import SwiftUI

@main
struct MotingApp: App {
    private let env: AppEnvironment?
    private let bootError: String?
    @StateObject private var recorder: RecordingController

    init() {
        do {
            let env = try AppEnvironment.bootstrap()
            self.env = env
            bootError = nil
            _recorder = StateObject(wrappedValue: RecordingController(env: env))
        } catch {
            env = nil
            bootError = "启动失败：\(error.localizedDescription)"
            _recorder = StateObject(wrappedValue: RecordingController(env: nil))
        }
    }

    var body: some Scene {
        Window("Moting", id: "main") {
            Group {
                if let env {
                    MeetingListView(repository: env.repository, recorder: recorder)
                } else {
                    Text(bootError ?? "").padding()
                }
            }
            .alert("出错了", isPresented: Binding(get: { recorder.lastError != nil },
                                                set: { if !$0 { recorder.lastError = nil } })) {
                Button("好") { recorder.lastError = nil }
            } message: {
                Text(recorder.lastError ?? "")
            }
        }
        MenuBarExtra {
            MenuBarContent(recorder: recorder)
        } label: {
            Image(systemName: recorder.state == .recording || recorder.state == .paused ? "record.circle.fill" : "waveform")
        }
    }
}

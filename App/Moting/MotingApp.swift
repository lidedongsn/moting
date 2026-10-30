import SwiftUI

@main
struct MotingApp: App {
    private let env: AppEnvironment?
    private let bootError: String?
    @StateObject private var recorder: RecordingController
    private let floatingPanel: FloatingPanelController

    init() {
        let recorder: RecordingController
        do {
            let env = try AppEnvironment.bootstrap()
            self.env = env
            bootError = nil
            recorder = RecordingController(env: env)
        } catch {
            env = nil
            bootError = "启动失败：\(error.localizedDescription)"
            recorder = RecordingController(env: nil)
        }
        _recorder = StateObject(wrappedValue: recorder)
        floatingPanel = FloatingPanelController(recorder: recorder)
    }

    var body: some Scene {
        Window("Moting", id: "main") {
            Group {
                if let env {
                    MainWindow(env: env, recorder: recorder, processing: recorder.processing)
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
        Settings {
            if let env {
                SettingsRoot(live: recorder.live, processing: recorder.processing, env: env)
            }
        }
        MenuBarExtra {
            MenuBarContent(recorder: recorder)
        } label: {
            if recorder.state == .recording || recorder.state == .paused {
                Image("MenuBarIconRecording").renderingMode(.original)
            } else {
                Image("MenuBarIcon")
            }
        }
    }
}

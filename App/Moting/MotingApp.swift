import SwiftUI

@main
struct MotingApp: App {
    private let env: AppEnvironment?
    private let bootError: String?
    @StateObject private var recorder: RecordingController
    private let floatingPanel: FloatingPanelController
    private let hotKey: GlobalHotKey

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
        // ⌥⌘R：任何 app 里开始 / 结束录音
        hotKey = GlobalHotKey { [weak recorder] in
            MainActor.assumeIsolated {
                guard let recorder else { return }
                switch recorder.state {
                case .recording, .paused: recorder.stop()
                case .stopping: break
                default: recorder.start()
                }
            }
        }
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
            MenuBarContent(recorder: recorder, live: recorder.live, processing: recorder.processing, env: env)
        } label: {
            if recorder.state == .recording || recorder.state == .paused || recorder.state == .stopping {
                // 录音中：菜单栏直接显示红点和计时
                HStack(spacing: 4) {
                    Image("MenuBarIconRecording").renderingMode(.original)
                    Text(clock(recorder.elapsed)).monospacedDigit()
                }
            } else {
                Image("MenuBarIcon")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

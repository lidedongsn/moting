import SwiftUI

@main
struct MotingApp: App {
    private let env: AppEnvironment?
    private let bootError: String?
    @StateObject private var recorder: RecordingController
    private let floatingPanel: FloatingPanelController
    private let callDetector: CallDetector
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
        // init 时 NSApp 可能还没就绪，放到下一轮再应用保存的外观
        DispatchQueue.main.async { AppAppearance.applySaved() }
        floatingPanel = FloatingPanelController(recorder: recorder)
        callDetector = CallDetector(recorder: recorder)
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
        .defaultSize(width: 1180, height: 800)
        .windowToolbarStyle(.unified)
        Settings {
            if let env {
                SettingsRoot(live: recorder.live, processing: recorder.processing, env: env, recorder: recorder)
            }
        }
        MenuBarExtra {
            MenuBarContent(recorder: recorder, processing: recorder.processing, env: env)
        } label: {
            MenuBarLabel(recorder: recorder)
        }
        .menuBarExtraStyle(.window)
    }
}

/// 菜单栏图标；它一直在，顺便负责响应"打开主窗口"的请求
private struct MenuBarLabel: View {
    @ObservedObject var recorder: RecordingController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
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
        .onReceive(NotificationCenter.default.publisher(for: ProcessingModel.openMainRequest)) { _ in
            openWindow(id: "main")
        }
    }
}

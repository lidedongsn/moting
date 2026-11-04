import AppKit
import Combine
import MotingCapture
import MotingCore
import SwiftUI

/// 自动发现会议：每秒看一次哪些 app 在用麦克风，飞书、腾讯会议等通话时提示录音，
/// 录音中通话软件放下麦克风时提示结束。只读系统状态，不录任何声音，不发任何数据
@MainActor
final class CallDetector: ObservableObject {
    static let enabledKey = "callDetection.enabled"

    @Published private(set) var prompt: CallWatch.Prompt?

    private let recorder: RecordingController
    private var watch = CallWatch()
    private var timer: Timer?
    private var polling = false
    private let started = Date()
    private var panel: CallPromptPanel?
    private var cancellables: Set<AnyCancellable> = []

    init(recorder: RecordingController) {
        self.recorder = recorder
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        // @Published 在赋值之前发通知：等赋值完成再显示，否则弹窗第一次读到的还是空值，一片空白
        $prompt
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] p in self?.showPanel(p) }
            .store(in: &cancellables)
    }

    private var isRecording: Bool {
        recorder.state == .recording || recorder.state == .paused || recorder.state == .stopping || recorder.isStarting
    }

    private func poll() {
        #if DEBUG
        if DemoScene.isActive { return }
        #endif
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else {
            if prompt != nil { watch = CallWatch(); prompt = nil }
            return
        }
        guard !polling else { return }
        polling = true
        Task.detached(priority: .utility) {
            let ids = MicUsage.activeInputBundleIDs()
            await MainActor.run {
                self.polling = false
                self.watch.observe(bundleIDs: ids, recording: self.isRecording, at: Date().timeIntervalSince(self.started))
                if self.watch.prompt != self.prompt { self.prompt = self.watch.prompt }
            }
        }
    }

    #if DEBUG
    func showDemoPrompt(_ p: CallWatch.Prompt) { prompt = p }
    #endif

    // MARK: - 用户操作

    func record() {
        guard case .offer(let app) = prompt else { return }
        recorder.start(source: app.isBrowser ? nil : app.name)
        // 下一次观察会因为开始录音而收回提示；先收起
        prompt = nil
    }

    func stopRecording() {
        recorder.stop()
        prompt = nil
    }

    /// 不录 / 继续录
    func dismiss() {
        watch.dismiss()
        prompt = nil
    }

    private func showPanel(_ p: CallWatch.Prompt?) {
        if p == nil {
            panel?.orderOut(nil)
            return
        }
        let panel = self.panel ?? CallPromptPanel(detector: self)
        self.panel = panel
        panel.present()
    }
}

/// 屏幕右上角的小提示窗：不抢焦点，共享屏幕时不被采集
final class CallPromptPanel: NSPanel {
    static let size = NSSize(width: 340, height: 96)

    init(detector: CallDetector) {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size),
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                   backing: .buffered, defer: false)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { standardWindowButton($0)?.isHidden = true }
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        sharingType = .none
        #if DEBUG
        if DemoScene.isActive { sharingType = .readOnly }
        #endif
        let host = NSHostingView(rootView: CallPromptView(detector: detector))
        host.sizingOptions = []
        contentView = host
    }

    func present() {
        if let screen = NSScreen.main?.visibleFrame {
            setFrame(NSRect(x: screen.maxX - Self.size.width - 16, y: screen.maxY - Self.size.height - 12,
                            width: Self.size.width, height: Self.size.height), display: true)
        }
        orderFrontRegardless()
    }
}

private struct CallPromptView: View {
    @ObservedObject var detector: CallDetector

    var body: some View {
        Group {
            switch detector.prompt {
            case .offer(let app):
                content(icon: "phone.fill",
                        title: app.isBrowser ? L("\(app.name) 里好像在开会") : L("「\(app.name)」正在通话"),
                        detail: L("要录下这场会议吗？"),
                        secondary: (L("不录"), detector.dismiss),
                        primary: (L("开始录音"), detector.record))
            case .ended(let app):
                content(icon: "phone.down.fill",
                        title: L("「\(app.name)」通话好像结束了"),
                        detail: L("录音还在继续。"),
                        secondary: (L("继续录"), detector.dismiss),
                        primary: (L("结束录音"), detector.stopRecording))
            case nil:
                Color.clear
            }
        }
        .hudPanel()
        .ignoresSafeArea()
    }

    private func content(icon: String, title: String, detail: String,
                         secondary: (String, () -> Void), primary: (String, () -> Void)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Label { Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1) } icon: {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                }
                Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
            }
            HStack(spacing: 8) {
                Spacer()
                Button(secondary.0, action: secondary.1).buttonStyle(AppButtonStyle())
                Button(primary.0, action: primary.1).buttonStyle(AppButtonStyle(kind: .record))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

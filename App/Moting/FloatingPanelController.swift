import AppKit
import Combine
import SwiftUI

/// B 款字幕卡片悬浮窗：置顶、不抢焦点、可拖动、浮在全屏 app 之上、共享屏幕时不被采集
@MainActor
final class FloatingPanelController {
    private let recorder: RecordingController
    private let ui = FloatingPanelState()
    private var panel: NSPanel?
    private var cancellables: Set<AnyCancellable> = []

    static let expandedSize = NSSize(width: 330, height: 220)
    static let collapsedSize = NSSize(width: 330, height: 44)
    /// 录音结束后显示精准转写进度时的高度（设计稿：紧凑卡片）
    static let processingHeight: CGFloat = 124
    static let maxSize = NSSize(width: 520, height: 480)
    /// 菜单栏面板的"显示字幕窗"：展开并带到最前
    static let showRequest = Notification.Name("moting.floatingPanel.show")

    init(recorder: RecordingController) {
        self.recorder = recorder
        // 录音中显示；录音结束后若进入会后精准转写，继续显示进度，处理完自动收起
        recorder.$state.combineLatest(recorder.processing.$lastRecordedMeetingID)
            .map { state, processingID in
                switch state {
                case .recording, .paused, .stopping: true
                case .stopped, .idle: processingID != nil
                }
            }
            .removeDuplicates()
            .sink { [weak self] visible in
                visible ? self?.show() : self?.hide()
            }
            .store(in: &cancellables)
        ui.$collapsed
            .dropFirst()
            .sink { [weak self] collapsed in self?.resize(collapsed: collapsed) }
            .store(in: &cancellables)
        // 录音结束转入进度显示：缩成紧凑卡片；再次开始录音：恢复展开高度
        recorder.$state
            .map { $0 == .recording || $0 == .paused || $0 == .stopping }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] recording in
                guard let self, !self.ui.collapsed, let panel = self.panel else { return }
                // 用户自己拉大过的窗口，开始录音时保留其尺寸
                if recording, panel.frame.height >= 120 { return }
                // @Published 在赋值前发出，这里要用传进来的新值，不能读 recorder.state
                self.resize(collapsed: false, recording: recording)
            }
            .store(in: &cancellables)
        ui.$opacity
            .sink { [weak self] v in self?.panel?.alphaValue = v }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: Self.showRequest)
            .sink { [weak self] _ in
                self?.ui.collapsed = false
                self?.show()
            }
            .store(in: &cancellables)
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        constrainToScreen(panel)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let size = ui.collapsed ? Self.collapsedSize : Self.expandedSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { panel.standardWindowButton($0)?.isHidden = true }
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // 共享屏幕时不被采集；新版 macOS 部分采集方式可能无视此设置，P2 实测
        panel.sharingType = .none
        #if DEBUG
        // 仅调试：允许截图核对界面
        if ProcessInfo.processInfo.environment["MOTING_CAPTURABLE"] == "1" { panel.sharingType = .readOnly }
        #endif
        panel.minSize = NSSize(width: 240, height: 40)
        panel.maxSize = Self.maxSize
        panel.alphaValue = ui.opacity
        let host = NSHostingView(rootView: FloatingPanelView(recorder: recorder, live: recorder.live, processing: recorder.processing, ui: ui))
        // 不让窗口跟随 SwiftUI 内容的理想高度变化：字幕越多窗口越高，会冲出屏幕。字幕在框内滚动
        host.sizingOptions = []
        panel.contentView = host
        if !panel.setFrameUsingName("MotingFloatingPanel") {
            // 首次出现：屏幕右下角
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 24, y: screen.minY + 24))
            }
        }
        panel.setFrameAutosaveName("MotingFloatingPanel")
        return panel
    }

    /// 收起 / 展开时保持顶边位置不变
    private func resize(collapsed: Bool, recording: Bool? = nil) {
        let isRecording = recording ?? self.isRecording
        guard let panel else { return }
        var frame = panel.frame
        let height = collapsed ? Self.collapsedSize.height : (isRecording ? Self.expandedSize.height : Self.processingHeight)
        let top = frame.maxY
        frame.size = NSSize(width: frame.width, height: height)
        frame.origin.y = top - height
        panel.setFrame(Self.constrained(frame, to: panel.screen ?? NSScreen.main), display: true, animate: true)
    }

    private var isRecording: Bool {
        recorder.state == .recording || recorder.state == .paused || recorder.state == .stopping
    }

    /// 修正超出大小范围或跑出屏幕的窗口（包括之前保存下来的异常尺寸）
    private func constrainToScreen(_ panel: NSPanel) {
        var frame = panel.frame
        let base = ui.collapsed ? Self.collapsedSize : Self.expandedSize
        if ui.collapsed {
            frame.size.height = base.height
        } else if frame.height < 120 {
            // 展开状态却恢复出收起时的高度（保存的窗口位置是收起时记下的）：恢复默认展开高度，顶边不动
            let top = frame.maxY
            frame.size.height = base.height
            frame.origin.y = top - base.height
        }
        if frame.height > Self.maxSize.height || frame.width > Self.maxSize.width {
            let top = frame.maxY
            frame.size = NSSize(width: min(frame.width, Self.maxSize.width), height: min(frame.height, Self.maxSize.height))
            frame.origin.y = top - frame.height
        }
        let fixed = Self.constrained(frame, to: panel.screen ?? NSScreen.main)
        if fixed != panel.frame { panel.setFrame(fixed, display: true) }
    }

    /// 把窗口完整放进屏幕可见区域内
    static func constrained(_ frame: NSRect, to screen: NSScreen?) -> NSRect {
        guard let visible = screen?.visibleFrame else { return frame }
        var f = frame
        f.size.width = min(f.width, visible.width)
        f.size.height = min(f.height, visible.height)
        f.origin.x = min(max(f.minX, visible.minX), visible.maxX - f.width)
        f.origin.y = min(max(f.minY, visible.minY), visible.maxY - f.height)
        return f
    }
}

/// 悬浮窗自身的界面状态，持久化到 UserDefaults
@MainActor
final class FloatingPanelState: ObservableObject {
    @Published var collapsed: Bool {
        didSet { UserDefaults.standard.set(collapsed, forKey: "floatingPanel.collapsed") }
    }
    @Published var opacity: CGFloat {
        didSet { UserDefaults.standard.set(Double(opacity), forKey: "floatingPanel.opacity") }
    }

    init() {
        collapsed = UserDefaults.standard.bool(forKey: "floatingPanel.collapsed")
        let saved = UserDefaults.standard.double(forKey: "floatingPanel.opacity")
        opacity = saved > 0 ? CGFloat(saved) : 1
    }
}

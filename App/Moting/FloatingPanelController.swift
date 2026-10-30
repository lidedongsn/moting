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

    static let expandedSize = NSSize(width: 300, height: 210)
    static let collapsedSize = NSSize(width: 300, height: 40)

    init(recorder: RecordingController) {
        self.recorder = recorder
        // 开始录音时自动弹出，结束后收起
        recorder.$state
            .removeDuplicates()
            .sink { [weak self] state in
                switch state {
                case .recording, .paused, .stopping: self?.show()
                case .stopped, .idle: self?.hide()
                }
            }
            .store(in: &cancellables)
        ui.$collapsed
            .dropFirst()
            .sink { [weak self] collapsed in self?.resize(collapsed: collapsed) }
            .store(in: &cancellables)
        ui.$opacity
            .sink { [weak self] v in self?.panel?.alphaValue = v }
            .store(in: &cancellables)
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
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
        panel.minSize = NSSize(width: 240, height: 40)
        panel.alphaValue = ui.opacity
        panel.contentView = NSHostingView(rootView: FloatingPanelView(recorder: recorder, live: recorder.live, ui: ui))
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
    private func resize(collapsed: Bool) {
        guard let panel else { return }
        var frame = panel.frame
        let target = collapsed ? Self.collapsedSize : Self.expandedSize
        let top = frame.maxY
        frame.size = NSSize(width: frame.width, height: target.height)
        frame.origin.y = top - target.height
        panel.setFrame(frame, display: true, animate: true)
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

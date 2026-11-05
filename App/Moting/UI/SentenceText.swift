import AppKit
import MotingCore
import SwiftUI

/// 让 SwiftUI 的按钮能操作文字视图（播放光标所在的句子）
@MainActor
final class SentenceTextHandle {
    weak var view: SentenceTextView?
}

/// 一段发言的正文。SwiftUI 的 Text 不知道点在了哪个字，所以用 NSTextView。
/// 阅读时：单击一句从这句开始播放，悬停时这句有淡底，拖选和复制照常。
/// 编辑时：同一个视图原地变成可编辑，字体和位置都不变；每句文字带隐藏标记，保存时对回各自的时间
struct SentenceText: NSViewRepresentable {
    let turnText: TurnText
    let segments: [TranscriptSegment]
    let currentSegment: UUID?
    let isPlaying: Bool
    let isEditing: Bool
    let handle: SentenceTextHandle
    let onSeek: (TranscriptSegment) -> Void
    let onTogglePlay: () -> Void
    let onBeginEdit: () -> Void
    let onDone: () -> Void
    let onCancel: () -> Void
    let onCommit: (TurnEdit.Result) -> Void
    let onRestore: () -> Void
    let onHeight: (CGFloat) -> Void

    func makeNSView(context: Context) -> SentenceTextView {
        // 显式用 TextKit 1，悬停高亮和按坐标找字都靠 NSLayoutManager
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let view = SentenceTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = false
        view.isHorizontallyResizable = false
        view.isRichText = true          // 否则隐藏标记留不住
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        return view
    }

    func updateNSView(_ view: SentenceTextView, context: Context) {
        handle.view = view
        view.onSeek = onSeek
        view.onTogglePlay = onTogglePlay
        view.onBeginEdit = onBeginEdit
        view.onDone = onDone
        view.onCancel = onCancel
        view.onCommit = onCommit
        view.onRestore = onRestore
        view.onHeight = onHeight
        view.segments = segments
        if isEditing {
            view.beginEditingIfNeeded(turnText)
        } else {
            view.finishEditingIfNeeded()
            view.apply(turnText, current: currentSegment, isPlaying: isPlaying)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: SentenceTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 480
        return CGSize(width: width, height: view.height(forWidth: width))
    }

    /// 编辑中滚出屏幕或切到别的会议时也要保存
    static func dismantleNSView(_ view: SentenceTextView, coordinator: ()) {
        view.finishEditingIfNeeded()
    }
}

final class SentenceTextView: NSTextView {
    var onSeek: ((TranscriptSegment) -> Void)?
    var onTogglePlay: (() -> Void)?
    var onBeginEdit: (() -> Void)?
    var onDone: (() -> Void)?
    var onCancel: (() -> Void)?
    var onCommit: ((TurnEdit.Result) -> Void)?
    var onRestore: (() -> Void)?
    var onHeight: ((CGFloat) -> Void)?
    var segments: [TranscriptSegment] = []
    private var turnText: TurnText?
    private var applied: (text: String, current: UUID?, isPlaying: Bool)?
    private var hovered: UUID?
    private var tracking: NSTrackingArea?
    private var editing = false

    /// 每句文字上的隐藏标记：值是这句的 id
    private static let segmentKey = NSAttributedString.Key("moting.segment")

    private static var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = Theme.readingLineSpacing
        return p
    }

    private static func baseAttributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: color, .paragraphStyle: paragraph]
    }

    func apply(_ t: TurnText, current: UUID?, isPlaying: Bool) {
        // 播放时每 0.1 秒都会走到这里，没变化就不碰文字（也不打断正在进行的选择）
        if let applied, applied.text == t.text, applied.current == current, applied.isPlaying == isPlaying { return }
        applied = (t.text, current, isPlaying)
        turnText = t
        let selection = selectedRange()
        let result = NSMutableAttributedString(string: t.text, attributes: Self.baseAttributes(color: isPlaying ? .secondaryLabelColor : .labelColor))
        if let hit = t.ranges.first(where: { $0.segment.id == current }) {
            result.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: hit.range)
        }
        textStorage?.setAttributedString(result)
        if NSMaxRange(selection) <= result.length { setSelectedRange(selection) }
        applyHover()
    }

    func height(forWidth width: CGFloat) -> CGFloat {
        guard let container = textContainer, let layout = layoutManager else { return 0 }
        container.size = NSSize(width: width, height: .greatestFiniteMagnitude)
        layout.ensureLayout(for: container)
        // 空文字时也留一行高度，光标才有地方
        return max(ceil(layout.usedRect(for: container).height), 20)
    }

    override func layout() {
        super.layout()
        textContainer?.size = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
    }

    // MARK: - 编辑

    func beginEditingIfNeeded(_ t: TurnText) {
        guard !editing else { return }
        editing = true
        turnText = t
        hovered = nil
        applyHover()
        let result = NSMutableAttributedString(string: t.text, attributes: Self.baseAttributes(color: .labelColor))
        for (i, item) in t.ranges.enumerated() {
            // 句子之间的空格归前一句
            let end = i + 1 < t.ranges.count ? t.ranges[i + 1].range.location : result.length
            result.addAttribute(Self.segmentKey, value: item.segment.id.uuidString,
                                range: NSRange(location: item.range.location, length: end - item.range.location))
        }
        textStorage?.setAttributedString(result)
        typingAttributes = Self.baseAttributes(color: .labelColor)
        isEditable = true
        undoManager?.removeAllActions(withTarget: textStorage as Any)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
            self.setSelectedRange(NSRange(location: result.length, length: 0))
            self.reportHeight()
        }
    }

    /// 退出编辑并保存
    func finishEditingIfNeeded() {
        guard editing else { return }
        let result = TurnEdit.changes(original: segments, runs: currentRuns())
        leaveEditing()
        // 这时可能正在更新视图，下一轮再改数据
        DispatchQueue.main.async { [onCommit] in onCommit?(result) }
    }

    private func leaveEditing() {
        editing = false
        isEditable = false
        applied = nil
        undoManager?.removeAllActions(withTarget: textStorage as Any)
        setSelectedRange(NSRange(location: 0, length: 0))
    }

    private func currentRuns() -> [(id: UUID?, text: String)] {
        guard let storage = textStorage else { return [] }
        var runs: [(id: UUID?, text: String)] = []
        let text = storage.string as NSString
        storage.enumerateAttribute(Self.segmentKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            runs.append(((value as? String).flatMap(UUID.init(uuidString:)), text.substring(with: range)))
        }
        return runs
    }

    /// 光标所在的句子，从这里开始播
    func playAtCursor() {
        guard let storage = textStorage, storage.length > 0 else { return }
        let index = min(selectedRange().location, storage.length - 1)
        let id = (storage.attribute(Self.segmentKey, at: index, effectiveRange: nil) as? String).flatMap(UUID.init(uuidString:))
        if let s = segments.first(where: { $0.id == id }) ?? segments.first { onSeek?(s) }
    }

    override func didChangeText() {
        super.didChangeText()
        reportHeight()
    }

    private func reportHeight() {
        onHeight?(height(forWidth: bounds.width > 0 ? bounds.width : 480))
    }

    /// 只接受纯文本，粘贴进来的不带格式
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    /// Esc：放弃这次修改
    override func cancelOperation(_ sender: Any?) {
        guard editing else { return super.cancelOperation(sender) }
        leaveEditing()
        onCancel?()
    }

    /// ⌘↩：完成
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if editing, event.keyCode == 36, event.modifierFlags.contains(.command) {
            onDone?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: - 找到鼠标下的那一句

    private func segment(at event: NSEvent) -> TranscriptSegment? {
        guard let layout = layoutManager, let container = textContainer, let turnText else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let glyph = layout.glyphIndex(for: point, in: container)
        // 行尾和文字下方的空白不算点在句子上
        guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(point) else { return nil }
        return turnText.segment(atCharacter: layout.characterIndexForGlyph(at: glyph))
    }

    override func mouseDown(with event: NSEvent) {
        if editing { return super.mouseDown(with: event) }
        let hit = event.clickCount == 1 ? segment(at: event) : nil
        // super 里会跟踪拖选，一直到松开鼠标才返回
        super.mouseDown(with: event)
        guard selectedRange().length == 0, let hit else { return }
        onSeek?(hit)
        // 单击不留键盘焦点，空格键继续控制播放
        window?.makeFirstResponder(nil)
    }

    /// 右键菜单最上面加编辑相关的项，系统的拷贝、查询等保留
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        guard !editing else { return menu }
        var index = 0
        func add(_ title: String, _ action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.insertItem(item, at: index)
            index += 1
        }
        add(L("编辑这段"), #selector(beginEditFromMenu))
        if segments.contains(where: \.isEdited) { add(L("恢复这段原文"), #selector(restoreFromMenu)) }
        menu.insertItem(.separator(), at: index)
        return menu
    }

    @objc private func beginEditFromMenu() { onBeginEdit?() }
    @objc private func restoreFromMenu() { onRestore?() }

    override func keyDown(with event: NSEvent) {
        let isSpace = event.charactersIgnoringModifiers == " "
        if editing {
            // ⌥空格：边听边改；普通空格就是输入空格
            if isSpace, event.modifierFlags.contains(.option) { playAtCursor() } else { super.keyDown(with: event) }
        } else if isSpace {
            onTogglePlay?()
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: - 悬停

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        if editing { return super.mouseMoved(with: event) }
        let id = segment(at: event)?.id
        if id != nil { NSCursor.pointingHand.set() } else { NSCursor.iBeam.set() }
        guard id != hovered else { return }
        hovered = id
        applyHover()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = nil
        applyHover()
        NSCursor.arrow.set()
    }

    private func applyHover() {
        guard let layout = layoutManager, let turnText else { return }
        let all = NSRange(location: 0, length: (turnText.text as NSString).length)
        layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        if let hit = turnText.ranges.first(where: { $0.segment.id == hovered }) {
            layout.addTemporaryAttribute(.backgroundColor, value: NSColor.labelColor.withAlphaComponent(0.08), forCharacterRange: hit.range)
        }
    }
}

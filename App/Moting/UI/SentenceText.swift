import AppKit
import MotingCore
import SwiftUI

/// 一段发言的正文。SwiftUI 的 Text 不知道点在了哪个字，所以用 NSTextView：
/// 单击一句从这句开始播放，悬停时这句有淡底；拖选和复制照常
struct SentenceText: NSViewRepresentable {
    let turnText: TurnText
    let currentSegment: UUID?
    let isPlaying: Bool
    let onSeek: (TranscriptSegment) -> Void
    let onTogglePlay: () -> Void
    let onEdit: () -> Void

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
        return view
    }

    func updateNSView(_ view: SentenceTextView, context: Context) {
        view.onSeek = onSeek
        view.onTogglePlay = onTogglePlay
        view.onEdit = onEdit
        view.apply(turnText, current: currentSegment, isPlaying: isPlaying)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: SentenceTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 480
        return CGSize(width: width, height: view.height(forWidth: width))
    }
}

final class SentenceTextView: NSTextView {
    var onSeek: ((TranscriptSegment) -> Void)?
    var onTogglePlay: (() -> Void)?
    var onEdit: (() -> Void)?
    private var turnText: TurnText?
    private var applied: (text: String, current: UUID?, isPlaying: Bool)?
    private var hovered: UUID?
    private var tracking: NSTrackingArea?

    func apply(_ t: TurnText, current: UUID?, isPlaying: Bool) {
        // 播放时每 0.1 秒都会走到这里，没变化就不碰文字（也不打断正在进行的选择）
        if let applied, applied.text == t.text, applied.current == current, applied.isPlaying == isPlaying { return }
        applied = (t.text, current, isPlaying)
        turnText = t
        let selection = selectedRange()
        let result = NSMutableAttributedString(string: t.text, attributes: [
            .font: NSFont.systemFont(ofSize: 15),
            .foregroundColor: isPlaying ? NSColor.secondaryLabelColor : NSColor.labelColor,
            .paragraphStyle: {
                let p = NSMutableParagraphStyle()
                p.lineSpacing = Theme.readingLineSpacing
                return p
            }(),
        ])
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
        return ceil(layout.usedRect(for: container).height)
    }

    override func layout() {
        super.layout()
        textContainer?.size = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
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
        let hit = event.clickCount == 1 ? segment(at: event) : nil
        // super 里会跟踪拖选，一直到松开鼠标才返回
        super.mouseDown(with: event)
        guard selectedRange().length == 0, let hit else { return }
        onSeek?(hit)
        // 单击不留键盘焦点，空格键继续控制播放
        window?.makeFirstResponder(nil)
    }

    /// 右键菜单最上面加"编辑这段"，系统的拷贝、查询等保留
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let item = NSMenuItem(title: L("编辑这段"), action: #selector(beginEdit), keyEquivalent: "")
        item.target = self
        menu.insertItem(item, at: 0)
        menu.insertItem(.separator(), at: 1)
        return menu
    }

    @objc private func beginEdit() { onEdit?() }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " { onTogglePlay?() } else { super.keyDown(with: event) }
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

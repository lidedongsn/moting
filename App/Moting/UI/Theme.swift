import AppKit
import MotingCore
import SwiftUI

/// 设计稿的配色与材质（docs/superpowers/design/2026-10-30-moting-ui.html）
enum Theme {
    /// 浅色界面用加深版（文字可读），深色界面用图标原色
    static let me = Color(light: 0x0FA3D8, dark: 0x3CD3FE)
    static let them = Color(light: 0xC99700, dark: 0xFFD600)
    static let record = Color(hex: 0xFF383C)
    static let mark = Color(hex: 0xE3A400)
    /// 说话人 1 之后按顺序循环
    private static let others: [Color] = [
        them, Color(hex: 0xF27A5E), Color(hex: 0xA27BFF), Color(hex: 0x5ED39A), Color(hex: 0xFF6FAE), Color(hex: 0x7FB2FF),
    ]

    /// index：0 = 我；1… = 其他人（SpeakerPalette 的编号）
    static func speaker(_ index: Int) -> Color {
        index <= 0 ? me : others[(index - 1) % others.count]
    }

    static func speaker(_ key: SpeakerKey, in indices: [SpeakerKey: Int]) -> Color {
        speaker(indices[key] ?? (key == .me ? 0 : 1))
    }

    /// 深色界面的三层底色：内容区最深，侧栏稍亮，卡片再亮一点（实色，不透出桌面）
    static let darkSidebar = Color(hex: 0x161618)

    /// 主窗口底色：内容区是阅读的纸面，侧栏和底部播放条退后一层
    static let canvas = Color(light: 0xFDFDFD, dark: 0x0E0E10)
    static let chrome = Color(light: 0xF4F4F5, dark: 0x161618)
    static let hairline = Color.primary.opacity(0.09)
    /// 设置页：底色退后，白卡片浮在上面
    static let settingsCanvas = Color(light: 0xF4F4F5, dark: 0x0E0E10)
    static let settingsSidebar = Color(light: 0xEBEBED, dark: 0x161618)
    static let card = Color(light: 0xFFFFFF, dark: 0x1C1C1F)

    /// 会议标题用衬线体：这是一份记录，不是一个面板
    static let titleFont = Font.system(size: 28, weight: .semibold, design: .serif)
    /// 转写稿和纪要的正文
    static let readingFont = Font.system(size: 15)
    static let readingLineSpacing: CGFloat = 5

    /// 圆角：按 macOS 15 的尺度（窗口约 10，系统设置分组约 10，控件约 6）。以后换 macOS 26 的大圆角只改这里
    enum Radius {
        /// 内容卡片、横幅
        static let card: CGFloat = 10
        /// 按钮、输入框、列表选中行、分段控件
        static let control: CGFloat = 6
        /// 所有按钮
        static let button: CGFloat = 7
        /// 小号分段控件里的滑块、设置侧栏图标
        static let small: CGFloat = 5
        /// 悬浮字幕窗、会议提醒这类浮在桌面上的小窗
        static let panel: CGFloat = 12
        /// 悬浮窗收起成一条时
        static let panelCollapsed: CGFloat = 14
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }

    /// 跟随系统深浅色
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// 卡片：实色 + 一条细描边，平铺不加阴影
struct GlassCard: ViewModifier {
    var radius: CGFloat = Theme.Radius.card
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content
            // 浅色下材质发灰，叠一层白（设计稿卡片约 75% 白）
            .background(Theme.card, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(scheme == .dark ? 0.12 : 0.08), lineWidth: 0.5)
            )
    }
}

extension View {
    func glassCard(radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(GlassCard(radius: radius))
    }
}

/// 小状态标签（转写中 / 等待电源 / 录音中 / 失败）
struct StatusTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 1.5)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// 00:00 或 0:00:00
func clock(_ t: TimeInterval) -> String {
    let s = max(0, Int(t))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}

/// 62 分钟 / 1 小时 12 分
func durationText(_ t: TimeInterval) -> String {
    let m = Int((t / 60).rounded())
    return m >= 60 ? L("\(m / 60) 小时 \(m % 60) 分") : L("\(max(m, 1)) 分钟")
}

/// 全 app 唯一的一套按钮：7pt 圆角、28pt 高、实色、无描边无阴影。
/// primary 是和播放键同款的黑白反色，一屏最多一个；record 只给录音相关的操作
struct AppButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger, record }
    var kind: Kind = .secondary
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        AppButton(configuration: configuration, kind: kind, iconOnly: iconOnly)
    }
}

/// 图标和文字都按行高居中，系统 Label 是按基线对齐的，放进按钮里会显得歪
private struct CenteredLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 12, weight: .medium))
            configuration.title
        }
    }
}

private struct AppButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: AppButtonStyle.Kind
    let iconOnly: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    private var fill: Color {
        let pressed = configuration.isPressed, active = hovering && isEnabled
        switch kind {
        case .primary: return Color.primary.opacity(pressed ? 0.7 : active ? 0.85 : 1)
        case .record: return Theme.record.opacity(pressed ? 0.75 : active ? 0.88 : 1)
        case .secondary, .danger: return Color.primary.opacity(pressed ? 0.18 : active ? 0.13 : 0.08)
        }
    }

    private var text: Color {
        switch kind {
        case .primary: Theme.canvas
        case .record: .white
        case .secondary: .primary
        case .danger: Color(light: 0xD70015, dark: 0xFF6961)
        }
    }

    var body: some View {
        configuration.label
            .labelStyle(CenteredLabelStyle())
            .font(.system(size: 13, weight: kind == .secondary || kind == .danger ? .regular : .medium))
            .foregroundStyle(text)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, iconOnly ? 0 : 12)
            .frame(width: iconOnly ? 28 : nil, height: 28)
            .background(fill, in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Rectangle())
            // 工具栏里 onHover 收不到事件，用连续悬停
            .onContinuousHover { phase in
                if case .active = phase { hovering = true } else { hovering = false }
            }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

/// 工具栏按钮
struct ToolbarPillStyle: ButtonStyle {
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        AppButtonStyle(kind: .secondary, iconOnly: iconOnly).makeBody(configuration: configuration)
    }
}

/// 胶囊分段切换（设计稿 .tabs / .seg）：页签用 regular，版本切换用 small
struct PillTabs<Value: Hashable>: View {
    struct Item {
        let value: Value
        let title: String
        var badge: String? = nil
    }

    enum Size { case regular, small }

    @Binding var selection: Value
    let items: [Item]
    var size: Size = .regular
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let small = size == .small
        let dark = scheme == .dark
        HStack(spacing: 2) {
            ForEach(items, id: \.value) { item in
                let on = item.value == selection
                Button { selection = item.value } label: {
                    HStack(spacing: 5) {
                        Text(item.title).fontWeight(on ? .semibold : .regular)
                        if let badge = item.badge { Text(badge).foregroundStyle(.secondary) }
                    }
                    .font(.system(size: small ? 11.5 : 13.5))
                    .foregroundStyle(on ? Color.primary : Color.secondary)
                    .padding(.horizontal, small ? 9 : 15)
                    .frame(height: small ? 22 : 30)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: small ? Theme.Radius.small : Theme.Radius.control, style: .continuous)
                                .fill(dark ? Color.white.opacity(0.16) : Color.white)
                                .shadow(color: .black.opacity(dark ? 0.3 : 0.08), radius: 2, y: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(small ? 2 : 3)
        .background(Color.primary.opacity(dark ? 0.07 : 0.05), in: RoundedRectangle(cornerRadius: small ? Theme.Radius.small + 2 : Theme.Radius.control + 3, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

/// 外观：跟随系统 / 浅色 / 深色，记在 UserDefaults，启动时和切换时应用到整个 app
enum AppAppearance: String, CaseIterable {
    case system, light, dark

    static let key = "appearance"

    var title: String {
        switch self {
        case .system: L("跟随系统")
        case .light: L("浅色")
        case .dark: L("深色")
        }
    }

    @MainActor
    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    @MainActor
    static func applySaved() {
        (AppAppearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system).apply()
    }
}

/// 进度环（设计稿 .ring）：20pt、描边 3.5pt，画在框内（描边不外溢）
struct ProgressRing: View {
    let progress: Double
    var dimmed = false
    private let width: CGFloat = 3.5

    var body: some View {
        ZStack {
            Circle().inset(by: width / 2).stroke(Theme.me.opacity(0.2), lineWidth: width)
            Circle().inset(by: width / 2)
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(dimmed ? Color.secondary : Theme.me, style: StrokeStyle(lineWidth: width, lineCap: .butt))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.3), value: progress)
        }
        .frame(width: 20, height: 20)
    }
}

/// 圆形按钮的悬停 / 按下反馈：悬停略放大提亮，按下略缩小
struct HoverGrowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverGrow(configuration: configuration)
    }

    private struct HoverGrow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let active = hovering && isEnabled
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.94 : active ? 1.08 : 1)
                .brightness(active && !configuration.isPressed ? 0.08 : 0)
                .shadow(color: .black.opacity(active ? 0.22 : 0), radius: 6, y: 2)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Circle())
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.12), value: hovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

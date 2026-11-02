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

/// 玻璃卡片：材质 + 细描边 + 顶部内高光（macOS 26 之前对 Liquid Glass 的近似）
struct GlassCard: ViewModifier {
    var radius: CGFloat = 14
    var material: Material = .regularMaterial

    func body(content: Content) -> some View {
        content
            .background(material, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.08)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.6)
            )
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
    }
}

extension View {
    func glassCard(radius: CGFloat = 14, material: Material = .regularMaterial) -> some View {
        modifier(GlassCard(radius: radius, material: material))
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
    return m >= 60 ? "\(m / 60) 小时 \(m % 60) 分" : "\(max(m, 1)) 分钟"
}

/// 工具栏胶囊按钮（设计稿 .tb）：系统工具栏在暗色下把文字画成次要灰，这里自绘
struct ToolbarPillStyle: ButtonStyle {
    var iconOnly = false

    func makeBody(configuration: Configuration) -> some View {
        ToolbarPill(configuration: configuration, iconOnly: iconOnly)
    }
}

/// 胶囊本体：悬停提亮、按下压暗（ButtonStyle 本身不能存悬停状态）
private struct ToolbarPill: View {
    let configuration: ButtonStyleConfiguration
    let iconOnly: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let active = hovering && isEnabled
        let fill: Color = dark
            ? .white.opacity(configuration.isPressed ? 0.3 : active ? 0.22 : 0.1)
            : configuration.isPressed ? .black.opacity(0.1) : active ? .black.opacity(0.05) : .white.opacity(0.65)
        configuration.label
            .font(.system(size: 13))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Color(hex: dark ? 0xF5F5F7 : 0x1D1D1F))
            .padding(.horizontal, iconOnly ? 0 : 12)
            .frame(width: iconOnly ? 28 : nil, height: 28)
            .background(fill, in: Capsule())
            .overlay(Capsule().strokeBorder(dark ? Color.white.opacity(active ? 0.3 : 0.14)
                                                 : Color.black.opacity(active ? 0.2 : 0.12), lineWidth: 0.5))
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
            // 工具栏里 onHover 收不到事件，用连续悬停
            .onContinuousHover { phase in
                if case .active = phase { hovering = true } else { hovering = false }
            }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
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
                            RoundedRectangle(cornerRadius: small ? 6 : 8, style: .continuous)
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
        .background(Color.primary.opacity(dark ? 0.07 : 0.05), in: RoundedRectangle(cornerRadius: small ? 8 : 11, style: .continuous))
        .animation(.easeOut(duration: 0.15), value: selection)
    }
}

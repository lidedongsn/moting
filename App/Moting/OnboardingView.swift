import AppKit
import AVFoundation
import MotingASR
import MotingCapture
import MotingCore
import SwiftUI
import UserNotifications

/// 第一次打开时的引导：说明产品、要权限、下模型、告诉用户怎么开始。每一步都能跳过
struct OnboardingView: View {
    private enum Step: Int, CaseIterable { case welcome, permissions, models, done }

    let env: AppEnvironment
    @ObservedObject var live: LiveTranscriptModel
    let onFinish: () -> Void
    @StateObject private var downloads: ModelDownloads
    @StateObject private var permissions = PermissionsModel()
    @State private var step: Step
    @Environment(\.openSettings) private var openSettings

    init(env: AppEnvironment, live: LiveTranscriptModel, onFinish: @escaping () -> Void) {
        self.env = env
        self.live = live
        self.onFinish = onFinish
        _downloads = StateObject(wrappedValue: ModelDownloads(store: env.modelStore))
        var first = Step.welcome
        #if DEBUG
        first = Step(rawValue: UserDefaults.standard.integer(forKey: "onboardingStep")) ?? .welcome
        #endif
        _step = State(initialValue: first)
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .permissions: permissionsStep
                case .models: modelsStep
                case .done: done
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 36)
            footer
        }
        .frame(width: 560, height: 460)
        .background(Theme.canvas)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // 从系统设置改完权限回来时刷新
            permissions.refresh()
        }
        .onAppear { permissions.refresh() }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Circle().fill(s == step ? Color.primary : Color.primary.opacity(0.2)).frame(width: 6, height: 6)
                }
            }
            Spacer()
            if step != .welcome && step != .done {
                Button("上一步") { go(-1) }.buttonStyle(AppButtonStyle())
            }
            switch step {
            case .welcome:
                Button("开始设置") { go(1) }.buttonStyle(AppButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            case .permissions:
                Button(permissions.requiredGranted ? L("继续") : L("稍后再说")) { go(1) }
                    .buttonStyle(AppButtonStyle(kind: permissions.requiredGranted ? .primary : .secondary))
            case .models:
                Button(allInstalled ? L("继续") : isDownloading ? L("后台下载，继续") : L("稍后再说")) { go(1) }
                    .buttonStyle(AppButtonStyle(kind: allInstalled ? .primary : .secondary))
            case .done:
                Button("开始使用", action: onFinish).buttonStyle(AppButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 0.5) }
    }

    private func go(_ delta: Int) {
        if let next = Step(rawValue: step.rawValue + delta) { step = next }
    }

    // MARK: - 欢迎

    private var welcome: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            // 直接读资源：applicationIconImage 走系统图标缓存，可能是旧图标
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
            Text("欢迎使用 Moting").font(Theme.titleFont)
            Text("录下每一场会议，分清谁说了什么，会后自动生成转写稿和纪要。")
                .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Label("录音和转写都在这台 Mac 上完成，不需要联网。只有你主动生成 AI 纪要时，才会发送转写文字。", systemImage: "lock.fill")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.chrome, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                .padding(.top, 10)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 权限

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("需要这些权限").font(Theme.titleFont)
            Text("录音需要同时听到你和对方。只在你开始录音时才会使用。")
                .font(.system(size: 13)).foregroundStyle(.secondary).padding(.bottom, 14)
            VStack(spacing: 0) {
                permissionRow(symbol: "mic.fill", color: .systemBlue, title: L("麦克风"), detail: L("录下你说的话"),
                              state: permissions.mic, request: permissions.requestMic, settings: "Privacy_Microphone")
                Divider().padding(.leading, 52)
                permissionRow(symbol: "speaker.wave.2.fill", color: .systemOrange, title: L("系统音频"), detail: L("录下会议里其他人的声音，你听到的声音不受影响"),
                              state: permissions.system, request: permissions.requestSystem, settings: "Privacy_AudioCapture")
                Divider().padding(.leading, 52)
                permissionRow(symbol: "bell.fill", color: .systemRed, title: L("通知（可选）"), detail: L("转写完成时告诉你"),
                              state: permissions.notifications, request: permissions.requestNotifications, settings: nil)
            }
            .glassCard()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionRow(symbol: String, color: NSColor, title: String, detail: String, state: PermissionsModel.State,
                               request: @escaping () -> Void, settings: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Color(nsColor: color), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch state {
            case .granted:
                Label("已允许", systemImage: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color(nsColor: .systemGreen))
            case .denied:
                Button("打开系统设置") { PermissionsModel.openSettings(settings) }.buttonStyle(AppButtonStyle())
            case .undetermined:
                Button("允许", action: request).buttonStyle(AppButtonStyle(kind: .primary))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }

    // MARK: - 模型

    /// 实时字幕 + 精准转写需要的全部模型。声纹模型只有登记声纹才用，到时再下
    private var offlineModels: [any DownloadableModel] {
        [OfflineCatalog.default, OfflineCatalog.vad, OfflineCatalog.segmentation]
    }

    private var totalSize: Int64 {
        offlineModels.reduce(live.selectedModel.totalSize) { $0 + $1.totalSize }
    }

    private var allInstalled: Bool {
        _ = downloads.revision
        return live.isInstalled(live.selectedModel) && offlineModels.allSatisfy(isInstalled)
    }

    private var isDownloading: Bool {
        !downloads.progress.isEmpty || live.downloads[live.selectedModel.id] != nil
    }

    private var overall: Double {
        var items = [Onboarding.Item(size: live.selectedModel.totalSize,
                                     fraction: live.isInstalled(live.selectedModel) ? 1 : live.downloads[live.selectedModel.id] ?? 0)]
        for m in offlineModels {
            items.append(.init(size: m.totalSize, fraction: isInstalled(m) ? 1 : downloads.progress[m.id] ?? 0))
        }
        return Onboarding.overallProgress(items)
    }

    private var downloadError: String? {
        if case .failed(let message) = live.modelState { return message }
        return offlineModels.compactMap { downloads.errors[$0.id] }.first
    }

    private var modelsStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("下载语音模型").font(Theme.titleFont)
            Text("模型保存在这台 Mac 上，识别时不需要联网。")
                .font(.system(size: 13)).foregroundStyle(.secondary).padding(.bottom, 14)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("实时字幕和会后精准转写").font(.system(size: 13, weight: .medium))
                        Text("共约 \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if allInstalled {
                        Label("已下载", systemImage: "checkmark.circle.fill").font(.system(size: 13)).foregroundStyle(Color(nsColor: .systemGreen))
                    } else if !isDownloading {
                        Button(downloadError == nil ? L("下载") : L("重试"), action: startDownloads).buttonStyle(AppButtonStyle(kind: .primary))
                    } else {
                        Text(verbatim: "\(Int(overall * 100))%").font(.system(size: 13)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if isDownloading { ProgressView(value: overall).progressViewStyle(.linear).tint(.accentColor) }
            }
            .padding(14)
            .glassCard()
            if let downloadError {
                VStack(alignment: .leading, spacing: 6) {
                    Text(downloadError).font(.system(size: 12)).foregroundStyle(Color(nsColor: .systemOrange)).fixedSize(horizontal: false, vertical: true)
                    Button("设置代理…") {
                        UserDefaults.standard.set("download", forKey: SettingsRoot.paneKey)
                        openSettings()
                    }
                    .buttonStyle(.link).font(.system(size: 12))
                }
                .padding(.top, 8)
            }
            Text("也可以先跳过：用到时会自动下载，已经录下的声音不会丢。").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 10)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startDownloads() {
        if !live.isInstalled(live.selectedModel) { live.installSelected() }
        for m in offlineModels where !isInstalled(m) { install(m) }
    }

    // any DownloadableModel 打开成具体类型
    private func install(_ m: some DownloadableModel) { downloads.install(m) }
    private func isInstalled(_ m: any DownloadableModel) -> Bool { installed(m) }
    private func installed(_ m: some DownloadableModel) -> Bool { env.modelStore.isInstalled(m) }

    // MARK: - 完成

    private var done: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(Color(nsColor: .systemGreen))
            Text("准备好了").font(Theme.titleFont)
            VStack(alignment: .leading, spacing: 10) {
                tip("record.circle", L("开会时点「开始录音」，或在任何 app 里按 ⌥⌘R"))
                tip("phone.fill", L("腾讯会议、飞书、钉钉开始通话时，会问你要不要录"))
                tip("menubar.rectangle", L("Moting 一直在菜单栏，关掉主窗口也能录"))
            }
            .padding(.top, 6)
            if !permissions.requiredGranted {
                Text("麦克风或系统音频还没有允许，录音时可能录不到声音。之后可以在系统设置里打开。").font(.system(size: 12)).foregroundStyle(Color(nsColor: .systemOrange))
                    .multilineTextAlignment(.center).padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 20)
            Text(text).font(.system(size: 13))
        }
    }
}

/// 三个权限的当前状态；从系统设置回来时刷新
@MainActor
final class PermissionsModel: ObservableObject {
    enum State { case granted, denied, undetermined }

    @Published private(set) var mic = State.undetermined
    @Published private(set) var system = State.undetermined
    @Published private(set) var notifications = State.undetermined

    var requiredGranted: Bool { mic == .granted && system == .granted }

    func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = .granted
        case .notDetermined: mic = .undetermined
        default: mic = .denied
        }
        switch SystemAudioPermission.status {
        case .granted: system = .granted
        case .denied: system = .denied
        case .undetermined: system = .undetermined
        }
        // 系统在后台线程回调：闭包必须标 @Sendable，否则继承主线程隔离，运行时检查会让 app 崩溃
        UNUserNotificationCenter.current().getNotificationSettings { @Sendable settings in
            let status = settings.authorizationStatus
            Task { @MainActor [weak self] in
                switch status {
                case .authorized, .provisional: self?.notifications = .granted
                case .denied: self?.notifications = .denied
                default: self?.notifications = .undetermined
                }
            }
        }
    }

    func requestMic() {
        AVCaptureDevice.requestAccess(for: .audio) { @Sendable _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func requestSystem() {
        SystemAudioPermission.request { @Sendable _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { @Sendable _, _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    /// 没给隐私子项时打开通知设置
    static func openSettings(_ privacyAnchor: String?) {
        let url = privacyAnchor.map { "x-apple.systempreferences:com.apple.preference.security?\($0)" }
            ?? "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

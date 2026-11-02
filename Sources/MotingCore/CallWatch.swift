import Foundation

/// 会议 / 通话软件
public struct CallApp: Hashable, Sendable {
    public let name: String
    /// 浏览器：网页会议，但也可能只是语音输入框，要占用更久才算通话
    public let isBrowser: Bool
    /// 占用麦克风多久算在通话
    public let minHold: TimeInterval
}

/// 认得的会议软件，按 bundle id 前缀匹配（含其 helper 进程，如 com.google.Chrome.helper）
public enum CallCatalog {
    private static let entries: [(prefixes: [String], app: CallApp)] = [
        (["com.tencent.meeting"], call("腾讯会议")),
        (["com.electron.lark", "com.bytedance.lark", "com.bytedance.feishu", "com.bytedance.macos.feishu", "com.larksuite"], call("飞书")),
        (["com.alibaba.DingTalkMac"], call("钉钉")),
        (["com.tencent.WeWorkMac"], call("企业微信")),
        (["us.zoom.xos"], call("Zoom")),
        (["com.microsoft.teams2", "com.microsoft.teams"], call("Teams")),
        (["Cisco-Systems.Spark", "com.webex.meetingmanager"], call("Webex")),
        (["com.apple.FaceTime"], call("FaceTime")),
        // 聊天软件也会为语音消息短暂开麦，要占用久一些才算通话
        (["com.tencent.xinWeChat"], chat("微信")),
        (["com.tencent.qq"], chat("QQ")),
        (["com.tinyspeck.slackmacgap"], chat("Slack")),
        (["com.hnc.Discord"], chat("Discord")),
        (["com.google.Chrome"], browser("Chrome")),
        (["com.apple.Safari", "com.apple.WebKit"], browser("Safari")),
        (["com.microsoft.edgemac"], browser("Edge")),
        (["company.thebrowser.Browser"], browser("Arc")),
        (["org.mozilla.firefox"], browser("Firefox")),
        (["com.brave.Browser"], browser("Brave")),
    ]

    private static func call(_ name: String) -> CallApp { CallApp(name: name, isBrowser: false, minHold: 2) }
    private static func chat(_ name: String) -> CallApp { CallApp(name: name, isBrowser: false, minHold: 20) }
    private static func browser(_ name: String) -> CallApp { CallApp(name: name, isBrowser: true, minHold: 20) }

    public static func app(forBundleID id: String) -> CallApp? {
        entries.first { e in e.prefixes.contains { id == $0 || id.hasPrefix($0 + ".") } }?.app
    }
}

/// 根据"哪些 app 正在用麦克风"判断要不要提示录音、通话是否已结束。
/// 每秒左右喂一次观察结果；不依赖系统，时间由调用方给。
public struct CallWatch: Sendable {
    public enum Prompt: Equatable, Sendable {
        /// 检测到通话，问要不要录
        case offer(CallApp)
        /// 录音中，通话软件不再用麦克风了，问要不要结束
        case ended(CallApp)
    }

    public private(set) var prompt: Prompt?

    /// 断开这么久以内算同一段占用（麦克风检测偶尔漏一两次）
    private let dropTolerance: TimeInterval = 3
    /// 不录的通话，要离开麦克风这么久才算下一场
    private let snoozeUntilGone: TimeInterval = 60

    private var since: [CallApp: TimeInterval] = [:]
    private var lastSeen: [CallApp: TimeInterval] = [:]
    private var snoozed: Set<CallApp> = []
    private var wasRecording = false
    /// 正在录的这场通话
    private var recordingCall: CallApp?
    private var endedDismissed = false

    public init() {}

    public mutating func observe(bundleIDs: Set<String>, recording: Bool, at t: TimeInterval) {
        let present = Set(bundleIDs.compactMap(CallCatalog.app(forBundleID:)))
        for app in present {
            if let last = lastSeen[app], t - last <= dropTolerance {
                // 同一段占用，起点不变
            } else {
                since[app] = t
            }
            lastSeen[app] = t
        }
        let on = lastSeen.filter { t - $0.value <= dropTolerance }.map(\.key)
        snoozed = snoozed.filter { app in lastSeen[app].map { t - $0 <= snoozeUntilGone } ?? false }

        if recording {
            if case .offer = prompt { prompt = nil }
            if recordingCall == nil {
                recordingCall = on.min { (since[$0] ?? t) < (since[$1] ?? t) }
            }
            if let call = recordingCall, !endedDismissed {
                prompt = on.contains(call) ? nil : .ended(call)
            }
        } else {
            if wasRecording {
                // 刚停止录音：还在进行的通话已经录过了，不再提示
                snoozed.formUnion(on)
                recordingCall = nil
                endedDismissed = false
                prompt = nil
            }
            if case .offer(let app) = prompt, !on.contains(app) { prompt = nil }
            if prompt == nil {
                let ready = on.filter { !snoozed.contains($0) && t - (since[$0] ?? t) >= $0.minHold }
                if let app = ready.min(by: { (since[$0] ?? t) < (since[$1] ?? t) }) { prompt = .offer(app) }
            }
        }
        wasRecording = recording
    }

    /// 用户点了"不录"或"继续录"
    public mutating func dismiss() {
        switch prompt {
        case .offer(let app): snoozed.insert(app)
        case .ended: endedDismissed = true
        case nil: break
        }
        prompt = nil
    }
}

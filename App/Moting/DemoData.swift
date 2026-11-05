#if DEBUG
import Foundation
import MotingCapture
import MotingCore
import MotingStorage

/// 调试用演示数据：设置环境变量 MOTING_DEMO_ROOT 后，app 用这个目录代替真实数据目录，
/// 第一次启动时写入几场虚构的会议。用于检查界面和制作产品截图，正式版不包含
enum DemoData {
    static var root: URL? {
        ProcessInfo.processInfo.environment["MOTING_DEMO_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private typealias Line = (who: String?, text: String)

    private static let review: [Line] = [
        (nil, "我们今天主要定一下支付改版的范围。上周灰度的数据大家都看了，转化涨了，但是退款咨询也跟着涨了。"),
        ("说话人 1", "对，我先说数据。新收银台的支付成功率从 91% 涨到了 94%。"),
        ("说话人 1", "但是退款相关的工单多了差不多三成，主要集中在分期这个入口。"),
        ("说话人 2", "分期入口这块我看过录屏，用户经常以为默认选的是全款，结果确认页才发现是分期。"),
        (nil, "所以问题不在流程长，是默认值和文案不清楚？"),
        ("说话人 2", "我倾向这么判断。确认页的金额字号也太小，分期手续费几乎看不见。"),
        ("说话人 3", "技术上改默认值很简单，配置就能发。文案和字号也是这周能上的。"),
        ("说话人 3", "麻烦的是对账。如果分期要拆到独立订单，后端差不多要三周。"),
        (nil, "拆单这次先不做。我们先把默认值改成全款，确认页把手续费单独列一行。"),
        ("说话人 1", "那我下周一再出一版灰度对比，看退款工单能不能降回去。"),
        (nil, "可以。成功标准就定退款工单回到改版前的水平，同时成功率不低于 93%。"),
        ("说话人 2", "确认页我今天下午出稿，明天上午走查。"),
        ("说话人 3", "周四可以提测，灰度放到周五。"),
        (nil, "周五灰度有点赶，万一出问题周末没人盯。"),
        ("说话人 3", "那放到下周二，周一我把回滚开关也一起做了。"),
        (nil, "好，就下周二。还有海外卡的问题，上次说要接入新的通道？"),
        ("说话人 1", "海外卡现在失败率还是偏高，主要是发卡行拒付。新通道商务还在谈，费率没定。"),
        (nil, "那这个不放进这一期了，下个月评审再看。"),
        ("说话人 2", "还有一个小问题，移动端的收银台要不要同步改？"),
        (nil, "同步改，不然两端文案不一致，客服解释起来更麻烦。"),
        ("说话人 3", "移动端发版周期长一点，我和客户端同学确认后在群里同步。"),
        (nil, "行。今天就到这，纪要我发群里。"),
    ]

    private static let reviewSummary = MeetingSummary(
        overview: "新收银台让支付成功率从 91% 提升到 94%，但分期入口带来的退款工单增加了约三成。团队判断主因是默认选项和确认页文案不清楚，决定本期只改默认值和手续费展示，拆单和海外卡通道延后。",
        topics: [
            .init(title: "退款工单上涨的原因", points: ["用户误以为默认是全款，到确认页才发现是分期", "确认页金额字号小，手续费几乎看不见"]),
            .init(title: "海外卡通道", points: ["失败率仍偏高，主要是发卡行拒付", "新通道费率未定，下月评审再看"]),
        ],
        decisions: ["默认选项改为全款，确认页单独列出分期手续费", "本期不做分期拆单", "灰度放到下周二，并先做好回滚开关", "移动端收银台同步修改"],
        todos: [
            .init(task: "出确认页设计稿并走查", owner: "周航", due: "明天上午", done: true),
            .init(task: "开发默认值与文案改动，加回滚开关", owner: "说话人 3", due: "下周一"),
            .init(task: "出灰度对比数据", owner: "林悦", due: "下周一"),
            .init(task: "确认移动端发版时间并在群里同步", owner: "说话人 3"),
        ])

    static func seedIfEmpty(paths: AppPaths, env: AppEnvironment) throws {
        // 目录名叫 empty 时不写入，用来看没有任何会议时的首屏
        guard paths.root.lastPathComponent != "empty", try env.repository.meetings(status: .done).isEmpty else { return }
        let now = Date()
        let day: TimeInterval = 86_400
        let main = try add(env, paths, title: "支付改版评审", start: now - 3_600, lines: review, secondsPerChar: 0.22,
                           names: ["说话人 1": "林悦", "说话人 2": "周航"])
        try env.summaries.save(meetingID: main, summary: reviewSummary, provider: "DeepSeek", model: "deepseek-flash", at: now - 3_000)
        for at in [46.0, 118.0, 201.0] { try env.repository.addMark(Mark(meetingID: main, at: at)) }
        let short = Array(review.prefix(8))
        _ = try add(env, paths, title: "产品周会", start: now - 6 * 3_600, lines: short, secondsPerChar: 0.3, names: ["说话人 1": "林悦"])
        _ = try add(env, paths, title: "客户回访：华东区续约", start: now - day - 3_600, lines: short, secondsPerChar: 0.34, names: [:])
        _ = try add(env, paths, title: "招聘同步", start: now - day - 5 * 3_600, lines: Array(review.prefix(4)), secondsPerChar: 0.3, names: [:])
        _ = try add(env, paths, title: "设计走查", start: now - 3 * day, lines: short, secondsPerChar: 0.26, names: ["说话人 2": "周航"])
        _ = try add(env, paths, title: "季度规划讨论", start: now - 9 * day, lines: review, secondsPerChar: 0.4, names: [:])
    }

    private static func add(_ env: AppEnvironment, _ paths: AppPaths, title: String, start: Date, lines: [Line],
                            secondsPerChar: Double, names: [String: String]) throws -> UUID {
        let id = UUID()
        var t = 1.5
        var timed: [(line: Line, start: Double, end: Double)] = []
        for line in lines {
            let length = Double(line.text.count) * secondsPerChar
            timed.append((line, t, t + length))
            t += length + 0.9
        }
        try env.repository.insert(Meeting(id: id, title: title, startedAt: start, endedAt: start + t, status: .done), tracks: [])
        let version = try env.transcripts.createVersion(meetingID: id, kind: .final, engine: "demo", model: "demo", createdAt: start)
        for item in timed {
            try env.transcripts.append(TranscriptSegment(versionID: version, channel: item.line.who == nil ? .mic : .system,
                                                         speakerLabel: item.line.who, start: item.start, end: item.end, text: item.line.text))
        }
        try env.transcripts.markCompleted(version, at: start)
        for (label, name) in names { try env.speakers.setName(meetingID: id, label: label, name: name) }
        try paths.ensureMeetingDirectory(id)
        for channel in AudioChannel.allCases {
            let spans = timed.filter { ($0.line.who == nil) == (channel == .mic) }
            try writeTrack(paths.trackURL(id, channel), seconds: t, spans: spans.map { ($0.start, $0.end) })
        }
        return id
    }

    /// 合成的"说话声"：随音节起伏的噪声，只为了让声纹带和播放有东西可看
    private static func writeTrack(_ url: URL, seconds: Double, spans: [(Double, Double)]) throws {
        let writer = try PCMTrackWriter(url: url)
        let rate = 16_000
        var generator = SystemRandomNumberGenerator()
        for second in 0..<Int(seconds.rounded(.up)) {
            var chunk = [Float](repeating: 0, count: rate)
            for i in 0..<rate {
                let time = Double(second) + Double(i) / Double(rate)
                guard spans.contains(where: { time >= $0.0 && time <= $0.1 }) else { continue }
                let syllable = 0.25 + 0.75 * abs(sin(time * 4.1) * sin(time * 1.3 + 0.7))
                chunk[i] = Float(syllable) * 0.3 * Float.random(in: -1...1, using: &generator)
            }
            try writer.append(chunk)
        }
        try writer.close()
    }
}
#endif

#if DEBUG
import AppKit
import MotingASR
import SwiftUI

/// 调试用：启动参数 -demoScene <名字> 直接显示录音相关的界面，不碰麦克风，用来检查设计。
/// recording / paused / processing / prompt / menu / menuRecording
@MainActor
enum DemoScene {
    nonisolated static var name: String? { UserDefaults.standard.string(forKey: "demoScene") }
    nonisolated static var isActive: Bool { name != nil }
    private static var keep: NSWindow?

    static func present(recorder: RecordingController, detector: CallDetector, env: AppEnvironment?) {
        guard let name else { return }
        DispatchQueue.main.async {
            switch name {
            case "recording", "paused":
                recorder.showDemoRecording(paused: name == "paused")
                recorder.live.showDemoLines(demoLines)
                recorder.showDemoDisk()
            case "processing":
                // 走真实流程：录音结束后悬浮窗才缩成进度卡片
                recorder.showDemoRecording(paused: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    recorder.showDemoStopped()
                    recorder.processing.showDemoProcessing(UUID(), status: .running, progress: 0.42)
                }
            case "prompt":
                if let app = CallCatalog.app(forBundleID: "com.electron.lark") { detector.showDemoPrompt(.offer(app)) }
            case "menu", "menuRecording":
                if name == "menuRecording" { recorder.showDemoRecording(paused: false) }
                let host = NSHostingView(rootView: MenuBarContent(recorder: recorder, processing: recorder.processing, env: env))
                let w = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 280, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
                w.contentView = host
                w.setContentSize(host.fittingSize)
                w.orderFrontRegardless()
                keep = w
            default: break
            }
        }
    }

    private static let demoLines: [SubtitleLine] = [
        ("我们今天主要定一下支付改版的范围。", AudioChannel.mic, true),
        ("上周灰度的数据大家都看了，转化涨了，但是退款咨询也跟着涨了。", .mic, true),
        ("对，我先说数据。新收银台的支付成功率从 91% 涨到了 94%。", .system, true),
        ("但是退款相关的工单多了差不多三成，主要集中在分期这个入口。", .system, true),
        ("所以问题不在流程长，是默认值和文案不清楚？", .mic, true),
        ("我倾向这么判断，确认页的金额字号也太", .system, false),
    ].map { SubtitleLine(id: UUID(), channel: $0.1, text: $0.0, isFinal: $0.2) }
}
#endif

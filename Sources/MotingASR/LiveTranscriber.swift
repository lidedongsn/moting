import Foundation
import MotingCore
import MotingDSP

public struct SubtitleLine: Identifiable, Sendable, Equatable {
    public var id: UUID
    public var channel: AudioChannel
    public var text: String
    public var isFinal: Bool

    public init(id: UUID, channel: AudioChannel, text: String, isFinal: Bool) {
        self.id = id
        self.channel = channel
        self.text = text
        self.isFinal = isFinal
    }
}

public enum TranscriptEvent: Sendable {
    case partial(SubtitleLine)
    case final(SubtitleLine, TranscriptSegment)
    /// 撤回已显示的草稿行（判为外放回声）
    case retract(UUID)
}

/// 会中实时转写：一个识别器，每路音频一个流；按轨道采样位置换算会议时间。
/// 所有识别在内部串行队列（.utility）上进行，不占用录音和界面线程
public final class LiveTranscriber: @unchecked Sendable {
    private struct ChannelState {
        let stream: RecognitionStream
        /// 仅麦克风一路：过滤远处说话与环境声
        var gate: NearVoiceGate?
        var sentenceID = UUID()
        var sentenceStart: Int?
        var position = 0
        var lastText = ""
        /// 当前句的草稿已显示在字幕里
        var shown = false
    }

    private static let rate = 16_000.0
    /// 当前句一直没有文字时，起点最多保留到 0.5 秒前，避免长时间静音把起点拉得很早
    private static let leadSamples = 8_000

    private let versionID: UUID
    private let onEvent: @Sendable (TranscriptEvent) -> Void
    private let queue = DispatchQueue(label: "moting.asr.live", qos: .utility)
    private var states: [AudioChannel: ChannelState] = [:]
    /// 外放时去掉麦克风里的扬声器回声（以系统音频一路为参考），只在 queue 上用
    private let echoFilter = MicEchoFilter()
    /// "对方"最近的文字（轨道采样位置），用来认出"我"一路里被识别成字的回声
    private var systemRecent: [(start: Int, end: Int, text: String)] = []

    /// versionID：本场会议的草稿版本
    public init(recognizer: StreamingRecognizing, versionID: UUID,
                onEvent: @escaping @Sendable (TranscriptEvent) -> Void) {
        self.versionID = versionID
        self.onEvent = onEvent
        for ch in AudioChannel.allCases {
            states[ch] = ChannelState(stream: recognizer.makeStream(), gate: ch == .mic ? NearVoiceGate() : nil)
        }
    }

    /// 接 RecordingSession.onTrackAudio
    public func feed(_ channel: AudioChannel, _ samples: [Float], startSample: Int) {
        queue.async { [self] in
            switch channel {
            case .system:
                echoFilter.reference(samples, start: startSample)
                recognize(.system, samples, startSample: startSample)
            case .mic:
                // 去回声要等参考到齐，输出可能晚一点、分块也可能和输入不同
                if let r = echoFilter.mic(samples, start: startSample) {
                    recognize(.mic, r.samples, startSample: r.start)
                }
            }
        }
    }

    private func recognize(_ channel: AudioChannel, _ samples: [Float], startSample: Int) {
        guard var st = states[channel] else { return }
        if st.sentenceStart == nil { st.sentenceStart = startSample }
        st.position = startSample + samples.count
        st.stream.accept(st.gate?.process(samples) ?? samples)
        st.stream.decode()
        let text = st.stream.text
        if text.isEmpty {
            st.sentenceStart = max(st.sentenceStart ?? 0, st.position - Self.leadSamples)
        }
        if st.stream.isEndpoint {
            if !text.isEmpty { emitFinal(channel, &st, text) }
            st.stream.reset()
            st.sentenceID = UUID()
            st.sentenceStart = nil
            st.lastText = ""
            st.shown = false
            if channel == .system { systemRecent.removeAll { $0.end < 0 } }   // 去掉进行中的那句（end 记为 -1）
        } else if text != st.lastText {
            st.lastText = text
            if channel == .system { noteSystemPartial(st, text) }
            if !text.isEmpty {
                if channel == .mic && isEcho(st, text) {
                    retractIfShown(&st)
                } else {
                    st.shown = true
                    onEvent(.partial(SubtitleLine(id: st.sentenceID, channel: channel, text: text, isFinal: false)))
                }
            }
        }
        states[channel] = st
    }

    /// 结束录音时调用：取出门限与识别器缓存中的尾部，把两路未定稿的文字作为 final 发出
    public func finish() {
        queue.async { [self] in flushAll() }
    }

    /// 同 finish，但等处理完再返回（app 退出时用，保证最后一句落库）
    public func finishAndWait() {
        queue.sync { flushAll() }
    }

    private func flushAll() {
        if let r = echoFilter.flush() { recognize(.mic, r.samples, startSample: r.start) }
        for ch in AudioChannel.allCases {
            guard var st = states[ch] else { continue }
            // 门限有 200ms 延迟线，补等长静音把尾部送出来；再补 0.5 秒静音让模型把最后几个字出完
            if var gate = st.gate {
                st.stream.accept(gate.process([Float](repeating: 0, count: gate.latency)))
                st.gate = gate
            }
            st.stream.accept([Float](repeating: 0, count: 8_000))
            st.stream.inputFinished()
            st.stream.decode()
            let text = st.stream.text.isEmpty ? st.lastText : st.stream.text
            if !text.isEmpty { emitFinal(ch, &st, text) }
            st.lastText = ""
            st.stream.reset()
            states[ch] = st
        }
    }

    /// 测试用：等待已排队的识别处理完
    func waitUntilIdle() {
        queue.sync {}
    }

    /// "对方"进行中的那句（end 记为 -1），每次更新替换
    private func noteSystemPartial(_ st: ChannelState, _ text: String) {
        systemRecent.removeAll { $0.end < 0 }
        if !text.isEmpty { systemRecent.append((st.sentenceStart ?? st.position, -1, text)) }
    }

    /// "我"这句与同时段"对方"的文字大致相同：判为外放回声
    private func isEcho(_ st: ChannelState, _ text: String) -> Bool {
        let slack = Int(EchoText.slack * Self.rate)
        let start = (st.sentenceStart ?? st.position) - slack, end = st.position + slack
        let theirs = systemRecent.filter { $0.start < end && ($0.end < 0 || $0.end > start) }.map(\.text).joined()
        return EchoText.isEcho(text, of: theirs)
    }

    private func retractIfShown(_ st: inout ChannelState) {
        if st.shown { onEvent(.retract(st.sentenceID)) }
        st.shown = false
    }

    private func emitFinal(_ channel: AudioChannel, _ st: inout ChannelState, _ text: String) {
        if channel == .mic && isEcho(st, text) {
            retractIfShown(&st)
            return
        }
        if channel == .system {
            systemRecent.removeAll { $0.end < 0 || $0.end < st.position - 30 * Int(Self.rate) }   // 只留最近 30 秒
            systemRecent.append((st.sentenceStart ?? st.position, st.position, text))
        }
        let start = Double(st.sentenceStart ?? st.position) / Self.rate
        let segment = TranscriptSegment(id: st.sentenceID, versionID: versionID, channel: channel,
                                        start: start, end: Double(st.position) / Self.rate, text: text)
        onEvent(.final(SubtitleLine(id: st.sentenceID, channel: channel, text: text, isFinal: true), segment))
    }
}

import Foundation
import MotingCore

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
}

/// 会中实时转写：一个识别器，每路音频一个流；按轨道采样位置换算会议时间。
/// 所有识别在内部串行队列（.utility）上进行，不占用录音和界面线程
public final class LiveTranscriber: @unchecked Sendable {
    private struct ChannelState {
        let stream: RecognitionStream
        var sentenceID = UUID()
        var sentenceStart: Int?
        var position = 0
        var lastText = ""
    }

    private static let rate = 16_000.0
    /// 当前句一直没有文字时，起点最多保留到 0.5 秒前，避免长时间静音把起点拉得很早
    private static let leadSamples = 8_000

    private let versionID: UUID
    private let onEvent: @Sendable (TranscriptEvent) -> Void
    private let queue = DispatchQueue(label: "moting.asr.live", qos: .utility)
    private var states: [AudioChannel: ChannelState] = [:]

    /// versionID：本场会议的草稿版本
    public init(recognizer: StreamingRecognizing, versionID: UUID,
                onEvent: @escaping @Sendable (TranscriptEvent) -> Void) {
        self.versionID = versionID
        self.onEvent = onEvent
        for ch in AudioChannel.allCases {
            states[ch] = ChannelState(stream: recognizer.makeStream())
        }
    }

    /// 接 RecordingSession.onTrackAudio
    public func feed(_ channel: AudioChannel, _ samples: [Float], startSample: Int) {
        queue.async { [self] in
            guard var st = states[channel] else { return }
            if st.sentenceStart == nil { st.sentenceStart = startSample }
            st.position = startSample + samples.count
            st.stream.accept(samples)
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
            } else if text != st.lastText {
                st.lastText = text
                if !text.isEmpty {
                    onEvent(.partial(SubtitleLine(id: st.sentenceID, channel: channel, text: text, isFinal: false)))
                }
            }
            states[channel] = st
        }
    }

    /// 结束录音时调用：把两路未定稿的文字作为 final 发出
    public func finish() {
        queue.async { [self] in
            for ch in AudioChannel.allCases {
                guard var st = states[ch], !st.lastText.isEmpty else { continue }
                emitFinal(ch, &st, st.lastText)
                st.lastText = ""
                states[ch] = st
            }
        }
    }

    /// 测试用：等待已排队的识别处理完
    func waitUntilIdle() {
        queue.sync {}
    }

    private func emitFinal(_ channel: AudioChannel, _ st: inout ChannelState, _ text: String) {
        let start = Double(st.sentenceStart ?? st.position) / Self.rate
        let segment = TranscriptSegment(id: st.sentenceID, versionID: versionID, channel: channel,
                                        start: start, end: Double(st.position) / Self.rate, text: text)
        onEvent(.final(SubtitleLine(id: st.sentenceID, channel: channel, text: text, isFinal: true), segment))
    }
}

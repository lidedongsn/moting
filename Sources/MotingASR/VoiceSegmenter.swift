import CSherpaOnnx
import Foundation

/// 一段人声：start 为在轨道中的采样位置
public struct SpeechSpan: Sendable, Equatable {
    public var start: Int
    public var samples: [Float]

    public init(start: Int, samples: [Float]) {
        self.start = start
        self.samples = samples
    }
}

/// 把整条轨道切成人声片段，便于逐段识别（测试可用假实现）
public protocol SpeechSegmenting {
    /// reader(offset, count) 分块读取轨道；每切出一段就回调，内存只占当前段
    func segment(reader: (Int, Int) throws -> [Float], total: Int, onSpan: (SpeechSpan) throws -> Void) throws
}

public enum OfflineASRError: Error, Equatable {
    case modelMissing(String)
    case createFailed(String)
}

/// Silero VAD 切分
public final class VoiceSegmenter: SpeechSegmenting {
    private let modelPath: String
    private let minSilence: Float
    private let maxSpan: Float
    /// 每次从文件读多少采样（10 秒）
    static let readChunk = 160_000

    public init(vadModel: URL, minSilence: TimeInterval = 0.5, maxSpan: TimeInterval = 20) throws {
        guard FileManager.default.fileExists(atPath: vadModel.path) else {
            throw OfflineASRError.modelMissing(vadModel.lastPathComponent)
        }
        modelPath = vadModel.path
        self.minSilence = Float(minSilence)
        self.maxSpan = Float(maxSpan)
    }

    public func segment(reader: (Int, Int) throws -> [Float], total: Int, onSpan: (SpeechSpan) throws -> Void) throws {
        let pool = CStringPool()
        var config = SherpaOnnxVadModelConfig()
        config.silero_vad.model = pool.c(modelPath)
        config.silero_vad.threshold = 0.5
        config.silero_vad.min_silence_duration = minSilence
        config.silero_vad.min_speech_duration = 0.25
        config.silero_vad.window_size = 512
        config.silero_vad.max_speech_duration = maxSpan
        config.sample_rate = 16_000
        config.num_threads = 1
        config.provider = pool.c("cpu")
        guard let vad = SherpaOnnxCreateVoiceActivityDetector(&config, 60) else {
            throw OfflineASRError.createFailed("VAD")
        }
        defer { SherpaOnnxDestroyVoiceActivityDetector(vad) }

        func drain() throws {
            while SherpaOnnxVoiceActivityDetectorEmpty(vad) == 0 {
                guard let seg = SherpaOnnxVoiceActivityDetectorFront(vad) else { break }
                let s = seg.pointee
                let span = SpeechSpan(start: Int(s.start), samples: Array(UnsafeBufferPointer(start: s.samples, count: Int(s.n))))
                SherpaOnnxDestroySpeechSegment(seg)
                SherpaOnnxVoiceActivityDetectorPop(vad)
                try onSpan(span)
            }
        }

        var offset = 0
        while offset < total {
            let chunk = try reader(offset, min(Self.readChunk, total - offset))
            if chunk.isEmpty { break }
            // 按 VAD 窗口（512 采样）逐块喂入，与官方用法一致；一次喂大块会导致切分错误
            chunk.withUnsafeBufferPointer { buf in
                var i = 0
                while i < buf.count {
                    let n = min(512, buf.count - i)
                    SherpaOnnxVoiceActivityDetectorAcceptWaveform(vad, buf.baseAddress! + i, Int32(n))
                    i += n
                }
            }
            offset += chunk.count
            try drain()
        }
        SherpaOnnxVoiceActivityDetectorFlush(vad)
        try drain()
    }
}

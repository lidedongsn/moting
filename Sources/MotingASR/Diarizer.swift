import CSherpaOnnx
import Foundation

public struct SpeakerTurn: Sendable, Equatable {
    public var start: TimeInterval
    public var end: TimeInterval
    public var speaker: Int

    public init(start: TimeInterval, end: TimeInterval, speaker: Int) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// 说话人分离（测试可用假实现）
public protocol Diarizing {
    func diarize(_ samples: [Float]) throws -> [SpeakerTurn]
}

/// pyannote 分段 + CAM++ 声纹聚类；说话人数自动判断
public final class SherpaDiarizer: Diarizing {
    /// 聚类阈值：越大越容易把相近的声音并成一个人
    public static let defaultThreshold: Float = 0.65   // 官方四人示例：0.5 分出 6 人，0.6–0.7 正好 4 人，0.8 起合并成 3 人
    private let handle: OpaquePointer

    public init(segmentation: AuxModel, embedding: AuxModel, directory: (AuxModel) -> URL,
                clusterThreshold: Float = SherpaDiarizer.defaultThreshold) throws {
        func path(_ m: AuxModel) throws -> String {
            guard let name = m.files.first?.name else { throw OfflineASRError.modelMissing(m.id) }
            let p = directory(m).appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: p) else { throw OfflineASRError.modelMissing(name) }
            return p
        }
        let pool = CStringPool()
        var config = SherpaOnnxOfflineSpeakerDiarizationConfig()
        config.segmentation.pyannote.model = pool.c(try path(segmentation))
        config.segmentation.num_threads = 2
        config.segmentation.provider = pool.c("cpu")
        config.embedding.model = pool.c(try path(embedding))
        config.embedding.num_threads = 2
        config.embedding.provider = pool.c("cpu")
        config.clustering.num_clusters = -1
        config.clustering.threshold = clusterThreshold
        config.min_duration_on = 0.3
        config.min_duration_off = 0.5
        guard let h = SherpaOnnxCreateOfflineSpeakerDiarization(&config) else {
            throw OfflineASRError.createFailed("diarization")
        }
        handle = h
    }

    deinit {
        SherpaOnnxDestroyOfflineSpeakerDiarization(handle)
    }

    public func diarize(_ samples: [Float]) throws -> [SpeakerTurn] {
        guard !samples.isEmpty else { return [] }
        let result = samples.withUnsafeBufferPointer {
            SherpaOnnxOfflineSpeakerDiarizationProcess(handle, $0.baseAddress, Int32($0.count))
        }
        guard let result else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result) }
        let n = Int(SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result))
        guard n > 0, let segs = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result) else { return [] }
        defer { SherpaOnnxOfflineSpeakerDiarizationDestroySegment(segs) }
        return (0..<n).map {
            SpeakerTurn(start: TimeInterval(segs[$0].start), end: TimeInterval(segs[$0].end), speaker: Int(segs[$0].speaker))
        }
    }
}

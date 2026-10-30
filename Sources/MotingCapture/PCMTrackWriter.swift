import Foundation

/// 16kHz 单声道 Int16 小端裸 PCM 写入器。文件已存在时追加（用于恢复后继续写）
public final class PCMTrackWriter {
    private let handle: FileHandle
    public private(set) var sampleCount: Int

    public init(url: URL) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        try PCMTrackReader.repair(url)
        handle = try FileHandle(forWritingTo: url)
        let end = try handle.seekToEnd()
        sampleCount = Int(end) / 2
    }

    public func append(_ samples: [Float]) throws {
        guard !samples.isEmpty else { return }
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, s) in samples.enumerated() {
                let clamped = max(-1, min(1, s))
                out[i] = Int16(clamped * Float(Int16.max)).littleEndian
            }
        }
        try handle.write(contentsOf: data)
        sampleCount += samples.count
    }

    public func appendSilence(_ count: Int) throws {
        guard count > 0 else { return }
        try handle.write(contentsOf: Data(count: count * 2))
        sampleCount += count
    }

    /// 强制落盘，防断电丢数据
    public func sync() throws {
        try handle.synchronize()
    }

    public func close() throws {
        try handle.synchronize()
        try handle.close()
    }
}

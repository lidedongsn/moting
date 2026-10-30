import Foundation

/// 把多路 16k Int16 PCM 轨道按采样相加混成一路，按需分段读取（不整体载入内存），用于回放
public final class PCMMixReader {
    private let handles: [FileHandle]
    private let counts: [Int]
    public let frameCount: Int

    /// 不存在的文件忽略
    public init(urls: [URL]) throws {
        var hs: [FileHandle] = []
        var cs: [Int] = []
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            hs.append(try FileHandle(forReadingFrom: url))
            cs.append(try PCMTrackReader.sampleCount(url))
        }
        handles = hs
        counts = cs
        frameCount = cs.max() ?? 0
    }

    deinit {
        handles.forEach { try? $0.close() }
    }

    /// 读取 [offset, offset + count) 的混音，超出总长的部分截掉
    public func read(at offset: Int, count: Int) throws -> [Float] {
        let n = max(0, min(count, frameCount - offset))
        guard n > 0 else { return [] }
        var mix = [Float](repeating: 0, count: n)
        for (h, total) in zip(handles, counts) where offset < total {
            let m = min(n, total - offset)
            try h.seek(toOffset: UInt64(offset * 2))
            guard let data = try h.read(upToCount: m * 2) else { continue }
            data.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: Int16.self)
                for i in 0..<min(m, p.count) { mix[i] += Float(Int16(littleEndian: p[i])) / Float(Int16.max) }
            }
        }
        for i in 0..<n { mix[i] = max(-1, min(1, mix[i])) }
        return mix
    }
}

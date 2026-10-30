import Foundation

/// 声纹带用的波形包络：分块顺序读取 16k Int16 轨道，每个分桶取峰值，再按全轨道最大值归一化到 0–1。
/// 只读一遍文件、内存与时长无关
public enum WaveformEnvelope {
    public static func compute(_ url: URL, bins: Int) throws -> [Float] {
        guard bins > 0 else { return [] }
        guard FileManager.default.fileExists(atPath: url.path) else { return Array(repeating: 0, count: bins) }
        let total = try PCMTrackReader.sampleCount(url)
        guard total > 0 else { return Array(repeating: 0, count: bins) }
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var peaks = [Float](repeating: 0, count: bins)
        var index = 0
        let chunk = 16_000
        while let data = try h.read(upToCount: chunk * 2), !data.isEmpty {
            data.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: Int16.self)
                for i in 0..<p.count {
                    let b = min(bins - 1, (index + i) * bins / total)
                    let v = abs(Float(Int16(littleEndian: p[i])))
                    if v > peaks[b] { peaks[b] = v }
                }
            }
            index += data.count / 2
        }
        let maxPeak = peaks.max() ?? 0
        return maxPeak > 0 ? peaks.map { $0 / maxPeak } : peaks
    }
}

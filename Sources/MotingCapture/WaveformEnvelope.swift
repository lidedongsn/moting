import Foundation

/// 声纹带用的波形包络：分块顺序读取 16k Int16 轨道，每个分桶取平均幅度（比峰值饱满、不尖），
/// 做一次三点平滑，再按最大值归一化到 0–1。只读一遍文件、内存与时长无关
public enum WaveformEnvelope {
    public static func compute(_ url: URL, bins: Int) throws -> [Float] {
        guard bins > 0 else { return [] }
        guard FileManager.default.fileExists(atPath: url.path) else { return Array(repeating: 0, count: bins) }
        let total = try PCMTrackReader.sampleCount(url)
        guard total > 0 else { return Array(repeating: 0, count: bins) }
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var sums = [Float](repeating: 0, count: bins)
        var counts = [Int](repeating: 0, count: bins)
        var index = 0
        let chunk = 16_000
        while let data = try h.read(upToCount: chunk * 2), !data.isEmpty {
            data.withUnsafeBytes { raw in
                let p = raw.bindMemory(to: Int16.self)
                for i in 0..<p.count {
                    let b = min(bins - 1, (index + i) * bins / total)
                    sums[b] += abs(Float(Int16(littleEndian: p[i])))
                    counts[b] += 1
                }
            }
            index += data.count / 2
        }
        let means = zip(sums, counts).map { $1 > 0 ? $0 / Float($1) : 0 }
        let smooth = means.indices.map { i in
            (means[max(0, i - 1)] + 2 * means[i] + means[min(means.count - 1, i + 1)]) / 4
        }
        let top = smooth.max() ?? 0
        return top > 0 ? smooth.map { $0 / top } : smooth
    }
}

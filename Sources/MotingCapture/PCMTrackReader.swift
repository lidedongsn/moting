import Foundation

public enum PCMTrackReader {
    public static func readAll(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        let count = data.count / 2
        return data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            return (0..<count).map { Float(Int16(littleEndian: p[$0])) / Float(Int16.max) }
        }
    }

    public static func sampleCount(_ url: URL) throws -> Int {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        return size / 2
    }

    /// 崩溃可能留下半个采样：文件长度为奇数时截掉最后 1 字节
    public static func repair(_ url: URL) throws {
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        guard size % 2 == 1 else { return }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.truncate(atOffset: UInt64(size - 1))
    }
}

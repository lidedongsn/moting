import Foundation

/// 磁盘空间提醒。只提醒，不挡录音，也不替用户删任何东西
public enum DiskSpace {
    public enum Level: Sendable { case ok, low, critical }

    /// 16kHz、16 位、两路未压缩：每小时占用
    public static let bytesPerHour: Int64 = 16_000 * 2 * 2 * 3_600
    /// 不足这么多就提醒（约够录 8 小时，同时给转写和其他程序留余地）
    public static let lowThreshold: Int64 = 2_000_000_000
    /// 不足这么多就紧急提醒（约够录 2 小时）
    public static let criticalThreshold: Int64 = 500_000_000

    /// 读不到可用空间时不提醒，免得误报
    public static func level(free: Int64?) -> Level {
        guard let free else { return .ok }
        if free < criticalThreshold { return .critical }
        return free < lowThreshold ? .low : .ok
    }

    /// 还能录多少小时
    public static func recordableHours(free: Int64) -> Double {
        Double(max(0, free)) / Double(bytesPerHour)
    }

    /// 这台 Mac 的可用空间，算上系统能腾出来的部分（和访达显示的一致）；读不到返回 nil
    public static func freeBytes(at url: URL) -> Int64? {
        // 路径可能还没创建（第一次启动），往上找到存在的目录
        var dir = url
        while !FileManager.default.fileExists(atPath: dir.path), dir.pathComponents.count > 1 { dir.deleteLastPathComponent() }
        return (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    /// 紧急提醒只在跌进紧急状态时发一次，空间恢复后才会再发
    public struct CriticalAlert: Sendable {
        private var notified = false

        public init() {}

        public mutating func shouldNotify(level: Level) -> Bool {
            guard level == .critical else {
                notified = false
                return false
            }
            defer { notified = true }
            return !notified
        }
    }
}

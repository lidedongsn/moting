import Foundation

/// 新手引导的判断逻辑
public enum Onboarding {
    public static let completedKey = "onboarding.completed"

    /// 老用户已经有会议记录了，不再引导
    public static func shouldShow(completed: Bool, hasMeetings: Bool) -> Bool {
        !completed && !hasMeetings
    }

    public struct Item: Sendable {
        public var size: Int64
        public var fraction: Double
        public init(size: Int64, fraction: Double) {
            self.size = size
            self.fraction = fraction
        }
    }

    /// 几个模型的总下载进度，按文件大小加权；没有要下载的算完成
    public static func overallProgress(_ items: [Item]) -> Double {
        let total = items.reduce(Int64(0)) { $0 + $1.size }
        guard total > 0 else { return 1 }
        let done = items.reduce(0.0) { $0 + Double($1.size) * min(1, max(0, $1.fraction)) }
        return done / Double(total)
    }
}

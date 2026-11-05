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

/// 用电池时精准转写要不要马上开始
public enum BatteryPolicy {
    public static let now = "now"
    public static let wait = "wait"

    /// 默认马上处理；只有用户在设置里选了等电源才等。用户手动点转写时永远不等
    public static func processNow(stored: String?, userInitiated: Bool) -> Bool {
        userInitiated || stored != wait
    }
}

import Foundation

/// 外放回声的文字判定：麦克风录进扬声器里对方的声音后，"我"一路会识别出与"对方"同时段大致相同的文字。
/// 去掉标点后，"我"这句有 60% 以上的字按顺序出现在同时段"对方"的文字里，就判为回声。
/// 太短的句子（"嗯""好的"）不判，免得删掉自己的应答。实时字幕和会后正式稿共用这条规则
public enum EchoText {
    public static let minChars = 3
    public static let minMatchRatio = 0.6
    /// 判断"同时段"时前后各放宽的秒数
    public static let slack: TimeInterval = 1.0

    public static func isEcho(_ mine: String, of theirs: String) -> Bool {
        let a = chars(mine)
        guard a.count >= minChars else { return false }
        let b = chars(theirs)
        guard !b.isEmpty else { return false }
        return Double(lcs(a, b)) / Double(a.count) >= minMatchRatio
    }

    /// 只留文字（汉字、字母、数字），去掉标点空白
    private static func chars(_ s: String) -> [Character] {
        s.filter { $0.isLetter || $0.isNumber }.map { $0 }
    }

    /// 最长公共子序列长度（识别有错字、断句不同也能对上）
    private static func lcs(_ a: [Character], _ b: [Character]) -> Int {
        var prev = [Int](repeating: 0, count: b.count + 1)
        var cur = prev
        for x in a {
            for (j, y) in b.enumerated() {
                cur[j + 1] = x == y ? prev[j] + 1 : max(prev[j + 1], cur[j])
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}

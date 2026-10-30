import Foundation

/// 会议导出为 Markdown（spec 5.7）。AI 纪要部分在 P4 加入
public enum MarkdownExporter {
    public static func export(meeting m: Meeting, segments: [TranscriptSegment], marks: [Mark],
                              timeZone: TimeZone = .current) -> String {
        var out = "# \(m.title)\n\n"
        out += "- 时间：\(timeRange(m, timeZone))\n"
        var speakers = ["我"]
        for s in segments.sorted(by: { $0.start < $1.start }) {
            let name = speakerName(s)
            if !speakers.contains(name) { speakers.append(name) }
        }
        out += "- 参会：\(speakers.joined(separator: "、"))\n"

        if !marks.isEmpty {
            out += "\n## 重点标记\n"
            for mark in marks.sorted(by: { $0.at < $1.at }) {
                out += "- [\(clock(mark.at))]\n"
            }
        }

        out += "\n## 转写稿\n\n"
        if segments.isEmpty {
            out += "（暂无转写内容）\n"
        } else {
            for s in segments.sorted(by: { $0.start < $1.start }) {
                out += "**[\(clock(s.start))] \(speakerName(s))：** \(s.text)\n\n"
            }
        }
        return out
    }

    public static func speakerName(_ s: TranscriptSegment) -> String {
        s.speakerLabel ?? (s.channel == .mic ? "我" : "对方")
    }

    /// 00:00:00
    public static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    private static func timeRange(_ m: Meeting, _ tz: TimeZone) -> String {
        let day = DateFormatter()
        day.timeZone = tz
        day.locale = Locale(identifier: "zh_CN")
        day.dateFormat = "yyyy-MM-dd HH:mm"
        let hm = DateFormatter()
        hm.timeZone = tz
        hm.dateFormat = "HH:mm"
        guard let end = m.endedAt else { return day.string(from: m.startedAt) }
        let minutes = Int((end.timeIntervalSince(m.startedAt) / 60).rounded())
        return "\(day.string(from: m.startedAt))–\(hm.string(from: end))（\(minutes) 分钟）"
    }
}

import Foundation

/// 会议导出为 Markdown（spec 5.7）：标题、时间、参会人、AI 纪要、重点标记、转写稿
public enum MarkdownExporter {
    /// names：说话人标签 → 用户改过的名字
    public static func export(meeting m: Meeting, segments: [TranscriptSegment], marks: [Mark],
                              names: [String: String] = [:], summary: MeetingSummary? = nil,
                              timeZone: TimeZone = .current) -> String {
        var out = "# \(m.title)\n\n"
        out += "- 时间：\(timeRange(m, timeZone))\n"
        var speakers = ["我"]
        for s in segments.sorted(by: { $0.start < $1.start }) {
            let name = speakerName(s, names)
            if !speakers.contains(name) { speakers.append(name) }
        }
        out += "- 参会：\(speakers.joined(separator: "、"))\n"
        if let summary { out += summarySection(summary) }

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
                out += "**[\(clock(s.start))] \(speakerName(s, names))：** \(s.text)\n\n"
            }
        }
        return out
    }

    private static func summarySection(_ s: MeetingSummary) -> String {
        var out = "\n## 纪要\n\n\(s.overview)\n"
        if !s.decisions.isEmpty {
            out += "\n### 决策\n" + s.decisions.map { "- \($0)\n" }.joined()
        }
        if !s.todos.isEmpty {
            out += "\n### 待办\n" + s.todos.map { t in
                let meta = [t.owner, t.due].compactMap { $0 }.filter { !$0.isEmpty }
                return "- [\(t.done ? "x" : " ")] \(t.task)\(meta.isEmpty ? "" : "（\(meta.joined(separator: " · "))）")\n"
            }.joined()
        }
        if !s.topics.isEmpty {
            out += "\n### 主要内容\n" + s.topics.map { t in
                "**\(t.title)**\n" + t.points.map { "- \($0)\n" }.joined()
            }.joined(separator: "\n")
        }
        return out
    }

    public static func speakerName(_ s: TranscriptSegment, _ names: [String: String] = [:]) -> String {
        if let label = s.speakerLabel { return names[label] ?? label }
        return s.channel == .mic ? "我" : "对方"
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

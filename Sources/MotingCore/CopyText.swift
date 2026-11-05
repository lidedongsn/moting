import Foundation

/// 一键复制的内容：纯文本，贴到微信、飞书都整齐，不带 Markdown 符号。
/// 用当前显示的文字：改过的句子、改过的名字都算数
public enum CopyText {
    public static func transcript(title: String, segments: [TranscriptSegment], names: [String: String]) -> String {
        let turns = TranscriptTurns.group(segments).map { turn in
            let name = MarkdownExporter.displayName(turn.segments[0], names)
            return "\(name) \(MarkdownExporter.clock(turn.start))\n\(TurnText(turn).text)"
        }
        return ([title] + turns).joined(separator: "\n\n")
    }

    public static func notes(title: String, summary s: MeetingSummary) -> String {
        var sections = [title, "\(L("概要"))\n\(s.overview)"]
        if !s.decisions.isEmpty {
            sections.append(([L("决策")] + s.decisions.map { "- \($0)" }).joined(separator: "\n"))
        }
        if !s.todos.isEmpty {
            sections.append(([L("待办")] + s.todos.map(todoLine)).joined(separator: "\n"))
        }
        if !s.topics.isEmpty {
            let topics = s.topics.map { t in ([t.title] + t.points.map { "- \($0)" }).joined(separator: "\n") }
            sections.append(L("议题") + "\n" + topics.joined(separator: "\n\n"))
        }
        return sections.joined(separator: "\n\n")
    }

    private static func todoLine(_ t: MeetingSummary.Todo) -> String {
        let meta = [t.owner, t.due].compactMap { $0 }.filter { !$0.isEmpty }
        let suffix = meta.isEmpty ? "" : L("（\(meta.joined(separator: " · "))）")
        return "- [\(t.done ? "x" : " ")] \(t.task)\(suffix)"
    }
}

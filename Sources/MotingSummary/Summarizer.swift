import Foundation
import MotingCore

/// 把模型回复的 JSON 解析成纪要；容忍 ```json 包裹，空负责人 / 截止时间当作没有
public enum SummaryParser {
    private struct Wire: Decodable {
        struct Topic: Decodable { let title: String?; let points: [String]? }
        struct Todo: Decodable { let task: String?; let owner: String?; let due: String? }
        let overview: String?
        let topics: [Topic]?
        let decisions: [String]?
        let todos: [Todo]?
    }

    public static func parse(_ text: String) throws -> MeetingSummary {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.drop { $0 != "\n" }.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.hasSuffix("```") { s = String(s.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        guard !s.isEmpty, let w = try? JSONDecoder().decode(Wire.self, from: Data(s.utf8)),
              let overview = w.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty else {
            throw SummaryError.unparseable(raw: text)
        }
        func clean(_ v: String?) -> String? {
            guard let t = v?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t
        }
        return MeetingSummary(
            overview: overview,
            topics: (w.topics ?? []).compactMap { t in clean(t.title).map { .init(title: $0, points: (t.points ?? []).compactMap(clean)) } },
            decisions: (w.decisions ?? []).compactMap(clean),
            todos: (w.todos ?? []).compactMap { t in clean(t.task).map { .init(task: $0, owner: clean(t.owner), due: clean(t.due)) } })
    }
}

/// 生成纪要：拼提示词（转写稿 + ★ 标记）、调用模型、解析失败重试一次；转写稿太长时分段总结再汇总
public struct Summarizer: Sendable {
    private let chat: ChatCompleting
    private let contextChars: Int

    public init(chat: ChatCompleting, contextChars: Int) {
        self.chat = chat
        self.contextChars = contextChars
    }

    /// names：说话人标签 → 改过的名字
    public func summarize(meeting: Meeting, segments: [TranscriptSegment], marks: [Mark],
                          names: [String: String]) async throws -> MeetingSummary {
        let sorted = segments.sorted { $0.start < $1.start }
        let lines = sorted.map { "[\(Self.clock($0.start))] \(MarkdownExporter.speakerName($0, names))：\($0.text)" }
        guard !lines.isEmpty else { throw SummaryError.emptyTranscript }
        let system = Template.system
        let date = Self.date(meeting.startedAt)
        let marksText = Self.marksText(marks, sorted, names)
        let chunks = Self.chunk(lines, limit: contextChars)
        if chunks.count == 1 {
            return try await ask(system, Template.user.fill(["title": meeting.title, "date": date, "part": "",
                                                            "marks": marksText, "transcript": chunks[0]]))
        }
        var parts: [MeetingSummary] = []
        for (i, c) in chunks.enumerated() {
            try Task.checkCancellation()
            parts.append(try await ask(system, Template.user.fill([
                "title": meeting.title, "date": date, "part": "（这是会议的第 \(i + 1)/\(chunks.count) 段）\n",
                "marks": marksText, "transcript": c])))
        }
        return try await merge(parts, title: meeting.title, date: date, system: system)
    }

    /// 汇总分段纪要；放不进一次请求时先按批汇总，再汇总各批，直到一次放得下
    private func merge(_ parts: [MeetingSummary], title: String, date: String, system: String) async throws -> MeetingSummary {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let texts = try parts.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        func prompt(_ batch: ArraySlice<String>) -> String {
            let body = batch.enumerated().map { "第 \($0.offset + 1) 段分段纪要：\n\($0.element)" }.joined(separator: "\n\n")
            return Template.merge.fill(["title": title, "date": date, "count": "\(batch.count)", "parts": body])
        }
        if texts.count == 1 { return parts[0] }
        if prompt(texts[...]).count - Template.merge.count <= contextChars {
            return try await ask(system, prompt(texts[...]))
        }
        // 按字数分批，每批至少两段，保证每轮都在收敛
        var merged: [MeetingSummary] = []
        var start = 0
        while start < texts.count {
            var end = start + 1
            while end < texts.count, prompt(texts[start...end]).count - Template.merge.count <= contextChars { end += 1 }
            end = max(end, min(start + 2, texts.count))
            try Task.checkCancellation()
            merged.append(end - start == 1 ? parts[start] : try await ask(system, prompt(texts[start..<end])))
            start = end
        }
        return try await merge(merged, title: title, date: date, system: system)
    }

    /// 调一次，解析不了再调一次
    private func ask(_ system: String, _ user: String) async throws -> MeetingSummary {
        var last = ""
        for _ in 0..<2 {
            last = try await chat.complete(system: system, user: user)
            if let s = try? SummaryParser.parse(last) { return s }
        }
        throw SummaryError.unparseable(raw: last)
    }

    /// 按行切段，每段字数不超过 limit（单行超长时单独成段）
    static func chunk(_ lines: [String], limit: Int) -> [String] {
        var out: [String] = [], cur = ""
        for l in lines {
            if !cur.isEmpty && cur.count + l.count + 1 > limit {
                out.append(cur)
                cur = ""
            }
            cur += cur.isEmpty ? l : "\n" + l
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// ★ 时间点 + 附近原文（标记前最近开始的一句）
    static func marksText(_ marks: [Mark], _ sorted: [TranscriptSegment], _ names: [String: String]) -> String {
        guard !marks.isEmpty else { return "（无）" }
        return marks.sorted { $0.at < $1.at }.map { m in
            let near = sorted.last { $0.start <= m.at + 1 }
            return "★ \(clock(m.at))" + (near.map { " 附近：\(MarkdownExporter.speakerName($0, names))：\($0.text)" } ?? "")
        }.joined(separator: "\n")
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func date(_ d: Date) -> String {
        d.formatted(.dateTime.year().month().day().hour().minute())
    }
}

/// 提示词模板（资源文件，代码里不写死）
enum Template {
    static let system = load("summary-system")
    static let user = load("summary-user")
    static let merge = load("summary-merge")

    private static func load(_ name: String) -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "txt"),
              let s = try? String(contentsOf: url, encoding: .utf8) else { fatalError("缺少提示词模板 \(name).txt") }
        return s
    }
}

extension String {
    /// 替换 {{key}} 占位符
    func fill(_ values: [String: String]) -> String {
        values.reduce(self) { $0.replacingOccurrences(of: "{{\($1.key)}}", with: $1.value) }
    }
}

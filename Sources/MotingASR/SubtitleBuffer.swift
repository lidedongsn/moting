import Foundation

/// 悬浮窗字幕：保留整场会议的字幕供往回翻看（上限 maxLines 防止无限增长）；同一 id 的 partial 原地更新，final 定稿
public struct SubtitleBuffer: Sendable, Equatable {
    private let maxLines: Int
    public private(set) var lines: [SubtitleLine] = []

    public init(maxLines: Int = 5000) {
        self.maxLines = maxLines
    }

    public mutating func apply(_ e: TranscriptEvent) {
        let line: SubtitleLine
        switch e {
        case .partial(let l): line = l
        case .final(let l, _): line = l
        }
        // 更新的总是最近几行，从后往前找
        if let i = lines.lastIndex(where: { $0.id == line.id }) {
            lines[i] = line
        } else {
            lines.append(line)
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        }
    }
}

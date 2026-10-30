import Foundation

/// 悬浮窗字幕：最多保留 maxLines 行；同一 id 的 partial 原地更新，final 定稿
public struct SubtitleBuffer: Sendable, Equatable {
    private let maxLines: Int
    public private(set) var lines: [SubtitleLine] = []

    public init(maxLines: Int = 6) {
        self.maxLines = maxLines
    }

    public mutating func apply(_ e: TranscriptEvent) {
        let line: SubtitleLine
        switch e {
        case .partial(let l): line = l
        case .final(let l, _): line = l
        }
        if let i = lines.firstIndex(where: { $0.id == line.id }) {
            lines[i] = line
        } else {
            lines.append(line)
            if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        }
    }
}

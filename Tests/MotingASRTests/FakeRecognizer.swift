import Foundation
import MotingCore
@testable import MotingASR

/// 按脚本返回结果的假识别器：第 N 次 decode 后返回 script[N]
final class FakeRecognizer: StreamingRecognizing {
    struct Step { var text: String; var endpoint: Bool = false }
    private let scripts: [[Step]]
    private var made = 0

    /// 每个流一份脚本，按 makeStream 的调用顺序分配
    init(_ scripts: [[Step]]) {
        self.scripts = scripts
    }

    func makeStream() -> RecognitionStream {
        defer { made += 1 }
        return FakeStream(script: made < scripts.count ? scripts[made] : [])
    }
}

final class FakeStream: RecognitionStream {
    private let script: [FakeRecognizer.Step]
    private var index = -1
    private var resetAt = -1

    init(script: [FakeRecognizer.Step]) {
        self.script = script
    }

    func accept(_ samples: [Float]) {}

    func decode() {
        index += 1
    }

    private var current: FakeRecognizer.Step? {
        index >= 0 && index < script.count && index > resetAt ? script[index] : nil
    }

    var text: String { current?.text ?? "" }
    var isEndpoint: Bool { current?.endpoint ?? false }

    func reset() {
        resetAt = index
    }
}

/// 收集转写事件
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [TranscriptEvent] = []
    func add(_ e: TranscriptEvent) { lock.withLock { items.append(e) } }
    var all: [TranscriptEvent] { lock.withLock { items } }
    var finals: [TranscriptSegment] {
        all.compactMap { if case .final(_, let s) = $0 { return s } else { return nil } }
    }
    var partialTexts: [String] {
        all.compactMap { if case .partial(let l) = $0 { return l.text } else { return nil } }
    }
}

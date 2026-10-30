import Foundation
import Testing
@testable import MotingCapture

private func track(_ seconds: [Float]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("moting-env-\(UUID().uuidString).pcm")
    let w = try PCMTrackWriter(url: url)
    for amp in seconds { try w.append((0..<16_000).map { Float(sin(Double($0) * 0.2)) * amp }) }
    try w.close()
    return url
}

@Test func envelopeHasFixedBins() throws {
    for n in [3, 30] {
        let url = try track(Array(repeating: 0.3, count: n))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try WaveformEnvelope.compute(url, bins: 50).count == 50)
    }
}

@Test func loudSectionIsHigher() throws {
    // 12 秒、每秒一段，第 6 秒很响；平滑只会影响紧挨的分段
    var secs = [Float](repeating: 0.05, count: 12)
    secs[6] = 0.8
    let url = try track(secs)
    defer { try? FileManager.default.removeItem(at: url) }
    let e = try WaveformEnvelope.compute(url, bins: 12)
    #expect(e[6] == 1)
    #expect(e[0] < 0.2 && e[3] < 0.2 && e[9] < 0.2 && e[11] < 0.2)
    #expect(e.allSatisfy { $0 >= 0 && $0 <= 1 })
}

@Test func missingTrackGivesZeros() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("moting-none-\(UUID().uuidString).pcm")
    #expect(try WaveformEnvelope.compute(url, bins: 8) == Array(repeating: 0, count: 8))
}

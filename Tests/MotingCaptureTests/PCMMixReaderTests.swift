import Foundation
import Testing
@testable import MotingCapture

private func track(_ values: [Float]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("moting-mix-\(UUID().uuidString).pcm")
    let w = try PCMTrackWriter(url: url)
    try w.append(values)
    try w.close()
    return url
}

private func near(_ a: [Float], _ b: [Float]) -> Bool {
    a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) < 1e-3 }
}

@Test func mixesTracksSampleBySample() throws {
    let a = try track([0.1, 0.2, 0.3, 0.4]), b = try track([0.1, -0.2, 0.0, 0.1])
    defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
    let r = try PCMMixReader(urls: [a, b])
    #expect(r.frameCount == 4)
    #expect(near(try r.read(at: 1, count: 2), [0.0, 0.3]))
}

@Test func shorterTrackIsPaddedWithSilence() throws {
    let a = try track([0.1, 0.1, 0.1, 0.1, 0.1]), b = try track([0.2, 0.2])
    defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
    let r = try PCMMixReader(urls: [a, b])
    #expect(r.frameCount == 5)
    #expect(near(try r.read(at: 0, count: 5), [0.3, 0.3, 0.1, 0.1, 0.1]))
}

@Test func readPastEndIsTruncated() throws {
    let a = try track([0.1, 0.2, 0.3])
    defer { try? FileManager.default.removeItem(at: a) }
    let r = try PCMMixReader(urls: [a])
    #expect(near(try r.read(at: 2, count: 10), [0.3]))
    #expect(try r.read(at: 5, count: 10).isEmpty)
}

@Test func mixIsClamped() throws {
    let a = try track([0.9]), b = try track([0.9])
    defer { [a, b].forEach { try? FileManager.default.removeItem(at: $0) } }
    #expect(near(try PCMMixReader(urls: [a, b]).read(at: 0, count: 1), [1.0]))
}

@Test func missingTrackIsIgnored() throws {
    let a = try track([0.5])
    defer { try? FileManager.default.removeItem(at: a) }
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("moting-none-\(UUID().uuidString).pcm")
    #expect(near(try PCMMixReader(urls: [a, missing]).read(at: 0, count: 1), [0.5]))
}

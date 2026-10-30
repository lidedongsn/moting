import Foundation
import Testing
@testable import MotingCapture

private func tempURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pcm")
}

@Test func pcmRoundTrip() throws {
    let url = tempURL()
    let w = try PCMTrackWriter(url: url)
    try w.append([0, 0.5, -0.5, 1.2])
    try w.close()
    let got = try PCMTrackReader.readAll(url)
    let want: [Float] = [0, 0.5, -0.5, 1.0]
    #expect(got.count == 4)
    for (a, b) in zip(got, want) { #expect(abs(a - b) <= 1.0 / 32768 + 1e-6) }
}

@Test func pcmSilenceAndCount() throws {
    let url = tempURL()
    let w = try PCMTrackWriter(url: url)
    try w.append([0.1, 0.2, 0.3])
    try w.appendSilence(5)
    #expect(w.sampleCount == 8)
    try w.close()
    #expect(try PCMTrackReader.sampleCount(url) == 8)
    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int == 16)
}

@Test func pcmRepairOddLength() throws {
    let url = tempURL()
    let w = try PCMTrackWriter(url: url)
    try w.append([0.1, 0.2])
    try w.close()
    let h = try FileHandle(forWritingTo: url)
    try h.seekToEnd()
    try h.write(contentsOf: Data([0x7F]))
    try h.close()
    try PCMTrackReader.repair(url)
    #expect(try PCMTrackReader.sampleCount(url) == 2)
    #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int == 4)
}

@Test func pcmWriterAppendsToExisting() throws {
    let url = tempURL()
    let w1 = try PCMTrackWriter(url: url)
    try w1.append([0.1, 0.2, 0.3, 0.4])
    try w1.close()
    let w2 = try PCMTrackWriter(url: url)
    #expect(w2.sampleCount == 4)
    try w2.append([0.5, 0.6])
    #expect(w2.sampleCount == 6)
    try w2.close()
    #expect(try PCMTrackReader.sampleCount(url) == 6)
}

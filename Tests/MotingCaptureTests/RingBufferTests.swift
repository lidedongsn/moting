import Foundation
import Testing
@testable import MotingCapture

private func write(_ r: SPSCRingBuffer, _ values: [Float]) -> Int {
    values.withUnsafeBufferPointer { r.write($0.baseAddress!, count: $0.count) }
}

private func read(_ r: SPSCRingBuffer, _ max: Int) -> [Float] {
    var out = [Float](repeating: 0, count: max)
    let n = out.withUnsafeMutableBufferPointer { r.read(into: $0.baseAddress!, maxCount: max) }
    return Array(out.prefix(n))
}

@Test func ringWrapsAround() {
    let r = SPSCRingBuffer(capacity: 8)
    #expect(write(r, [1, 2, 3, 4, 5, 6]) == 6)
    #expect(read(r, 6) == [1, 2, 3, 4, 5, 6])
    #expect(write(r, [7, 8, 9, 10, 11, 12]) == 6)
    #expect(r.availableToRead == 6)
    #expect(read(r, 10) == [7, 8, 9, 10, 11, 12])
}

@Test func ringDropsWhenFull() {
    let r = SPSCRingBuffer(capacity: 8)
    #expect(write(r, (0..<10).map(Float.init)) == 8)
    #expect(r.droppedSamples == 2)
    #expect(read(r, 10) == (0..<8).map(Float.init))
}

@Test func ringConcurrentSPSC() async {
    let r = SPSCRingBuffer(capacity: 1024)
    let total = 1_000_000
    let producer = Thread {
        var next: Float = 0
        var chunk = [Float](repeating: 0, count: 64)
        while next < Float(total) {
            let n = min(64, total - Int(next))
            for i in 0..<n { chunk[i] = next + Float(i) }
            let written = chunk.withUnsafeBufferPointer { r.write($0.baseAddress!, count: n) }
            // 满了就把没写进去的部分重试，保证序列完整
            next += Float(written)
        }
    }
    producer.start()
    var expected: Float = 0
    var ok = true
    var buf = [Float](repeating: 0, count: 256)
    while expected < Float(total) {
        let n = buf.withUnsafeMutableBufferPointer { r.read(into: $0.baseAddress!, maxCount: 256) }
        for i in 0..<n where buf[i] != expected + Float(i) { ok = false }
        expected += Float(n)
    }
    #expect(ok)
    #expect(expected == Float(total))
}

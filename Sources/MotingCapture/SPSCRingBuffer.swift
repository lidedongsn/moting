import Atomics

/// 单生产者单消费者的无锁环形缓冲。
/// 生产者在 Core Audio 实时线程调用 write：不分配内存、不加锁。
public final class SPSCRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int
    private let mask: Int
    // 单调递增的读写计数，取模得到下标
    private let head = ManagedAtomic<Int>(0)   // 已写入总数
    private let tail = ManagedAtomic<Int>(0)   // 已读出总数
    private let dropped = ManagedAtomic<Int>(0)

    public init(capacity: Int) {
        var c = 1
        while c < max(capacity, 2) { c <<= 1 }
        self.capacity = c
        self.mask = c - 1
        storage = .allocate(capacity: c)
        storage.initialize(repeating: 0, count: c)
    }

    deinit {
        storage.deallocate()
    }

    public var availableToRead: Int {
        head.load(ordering: .acquiring) - tail.load(ordering: .acquiring)
    }

    public var droppedSamples: Int { dropped.load(ordering: .relaxed) }

    /// 空间不足时丢弃多余部分，返回实际写入数
    @discardableResult
    public func write(_ src: UnsafePointer<Float>, count: Int) -> Int {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let n = min(count, capacity - (h - t))
        if n < count { dropped.wrappingIncrement(by: count - n, ordering: .relaxed) }
        guard n > 0 else { return 0 }
        let start = h & mask
        let first = min(n, capacity - start)
        (storage + start).update(from: src, count: first)
        if n > first { storage.update(from: src + first, count: n - first) }
        head.store(h + n, ordering: .releasing)
        return n
    }

    public func read(into dst: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let n = min(maxCount, h - t)
        guard n > 0 else { return 0 }
        let start = t & mask
        let first = min(n, capacity - start)
        dst.update(from: storage + start, count: first)
        if n > first { (dst + first).update(from: storage, count: n - first) }
        tail.store(t + n, ordering: .releasing)
        return n
    }
}

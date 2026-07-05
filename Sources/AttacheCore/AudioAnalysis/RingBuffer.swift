public struct RingBuffer {
    public let capacity: Int
    private var storage: [Float]
    private var writeIndex = 0
    public private(set) var count = 0

    public init(capacity: Int) {
        self.capacity = max(1, capacity)
        self.storage = [Float](repeating: 0, count: self.capacity)
    }

    public mutating func append(_ samples: [Float]) {
        let n = samples.count
        guard n > 0 else { return }

        // Inputs larger than the ring are rare (chunks are far smaller than the
        // one-second history); keep the simple scalar wraparound for that case.
        if n >= capacity {
            for sample in samples {
                storage[writeIndex] = sample
                writeIndex = (writeIndex + 1) % capacity
            }
            count = capacity
            return
        }

        storage.withUnsafeMutableBufferPointer { dst in
            samples.withUnsafeBufferPointer { src in
                guard let dstBase = dst.baseAddress, let srcBase = src.baseAddress else { return }
                let first = min(n, capacity - writeIndex)
                (dstBase + writeIndex).update(from: srcBase, count: first)
                if n > first {
                    dstBase.update(from: srcBase + first, count: n - first)
                }
            }
        }
        writeIndex = (writeIndex + n) % capacity
        count = min(count + n, capacity)
    }

    public func latest(_ n: Int) -> [Float] {
        let wanted = min(max(0, n), capacity)
        guard wanted > 0 else { return [] }
        var output = [Float](repeating: 0, count: wanted)
        let start = (writeIndex - wanted + capacity) % capacity
        output.withUnsafeMutableBufferPointer { out in
            storage.withUnsafeBufferPointer { src in
                guard let outBase = out.baseAddress, let srcBase = src.baseAddress else { return }
                let first = min(wanted, capacity - start)
                outBase.update(from: srcBase + start, count: first)
                if wanted > first {
                    (outBase + first).update(from: srcBase, count: wanted - first)
                }
            }
        }
        return output
    }
}

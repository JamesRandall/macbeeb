import Synchronization

/// A single-producer, single-consumer ring of audio samples. The emulation
/// thread writes; the audio render callback reads. Lock-free, so safe to
/// read from a real-time thread.
public final class SampleRing: @unchecked Sendable {
    public let capacity: Int
    let storage: UnsafeMutablePointer<Float>
    /// Total samples written and read, ever. Only the producer stores
    /// `written`, only the consumer stores `read`.
    let written = Atomic<Int>(0)
    let read = Atomic<Int>(0)

    public init(capacity: Int) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deallocate()
    }

    /// Samples waiting to be read.
    public var count: Int {
        written.load(ordering: .acquiring) - read.load(ordering: .acquiring)
    }

    /// Producer: appends a sample, dropping it if the ring is full.
    @inline(__always)
    public func write(_ sample: Float) {
        let w = written.load(ordering: .relaxed)
        guard w - read.load(ordering: .acquiring) < capacity else { return }
        storage[w % capacity] = sample
        written.store(w + 1, ordering: .releasing)
    }

    /// Consumer: fills `buffer`, padding with the last sample (to avoid a
    /// click) if there aren't enough. Returns how many were real.
    public func read(into buffer: UnsafeMutableBufferPointer<Float>) -> Int {
        let r = read.load(ordering: .relaxed)
        let available = written.load(ordering: .acquiring) - r
        let n = min(available, buffer.count)
        for i in 0..<n {
            buffer[i] = storage[(r + i) % capacity]
        }
        let last = n > 0 ? buffer[n - 1] : (r > 0 ? storage[(r - 1) % capacity] : 0)
        for i in n..<buffer.count {
            buffer[i] = last
        }
        read.store(r + n, ordering: .releasing)
        return n
    }

    /// Consumer: drops everything waiting (sound from before it was heard).
    public func discardAll() {
        read.store(written.load(ordering: .acquiring), ordering: .releasing)
    }
}

import Foundation

extension Collection where Element: Sendable {
    /// Like `map`, but runs `transform` for every element concurrently and returns the results
    /// in the original order.
    public func asyncMap<T: Sendable>(_ transform: @Sendable @escaping (Element) async throws -> T) async rethrows -> [T] {
        try await withThrowingTaskGroup(of: (Int, T).self) { group in
            for (index, element) in self.enumerated() {
                group.addTask {
                    let value = try await transform(element)
                    return (index, value)
                }
            }

            var results = Array<T?>(repeating: nil, count: self.count)
            for try await (index, result) in group {
                results[index] = result
            }

            return results.map { $0! }
        }
    }
}

extension Collection {
    /// The element at `index`, or nil if it's out of bounds.
    public subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension Int {
    /// Splits `0..<self` into contiguous, roughly-equal ranges — one per available core, capped so
    /// a chunk is never smaller than `threshold` — or a single range covering everything when
    /// `self` doesn't clear that threshold. Used to hand large per-element workloads (mesh
    /// triangles, edges) to `DispatchQueue.concurrentPerform` in chunks sized for the machine,
    /// rather than either one task per element (too much overhead) or one task overall (no
    /// parallelism).
    func chunkedRanges(threshold: Int) -> [Range<Int>] {
        guard self > threshold else { return [0..<self] }
        let chunkCount = Swift.max(1, Swift.min(ProcessInfo.processInfo.activeProcessorCount, self / threshold))
        let size = (self + chunkCount - 1) / chunkCount
        return stride(from: 0, to: self, by: size).map { $0..<Swift.min($0 + size, self) }
    }
}

/// Backing storage for a `DispatchQueue.concurrentPerform`-based chunked computation — one slot
/// per chunk (or per element, if every element gets its own iteration). Each iteration writes to
/// a distinct index, so concurrent access is safe despite the lack of locking — `@unchecked
/// Sendable` reflects that externally-enforced disjointness rather than internal safety.
final class ChunkStorage<Element>: @unchecked Sendable {
    private let buffer: UnsafeMutableBufferPointer<Element?>

    init(count: Int) {
        buffer = .allocate(capacity: count)
        buffer.initialize(repeating: nil)
    }

    deinit {
        buffer.deinitialize()
        buffer.deallocate()
    }

    subscript(index: Int) -> Element? {
        get { buffer[index] }
        set { buffer[index] = newValue }
    }

    var results: [Element] { buffer.map { $0! } }
}

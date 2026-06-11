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

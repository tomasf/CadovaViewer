extension Sequence {
    /// Consecutive pairs that wrap around, so the last element is paired with the first:
    /// `[a, b, c]` → `[(a, b), (b, c), (c, a)]`.
    public func cyclicPairs() -> [(Element, Element)] {
        .init(zip(self, dropFirst() + Array(prefix(1))))
    }
}

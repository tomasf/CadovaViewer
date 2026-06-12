import Testing
@testable import ViewerCore

struct CyclicPairsTests {
    @Test func `cyclic pairs wrap the last element back to the first`() {
        let pairs = [1, 2, 3].cyclicPairs()
        #expect(pairs.map(\.0) == [1, 2, 3])
        #expect(pairs.map(\.1) == [2, 3, 1])
    }

    @Test func `cyclic pairs of two elements yields both orderings`() {
        let pairs = ["a", "b"].cyclicPairs()
        #expect(pairs.map { "\($0.0)\($0.1)" } == ["ab", "ba"])
    }

    @Test func `cyclic pairs of a single element pairs it with itself`() {
        let pairs = [42].cyclicPairs()
        #expect(pairs.count == 1)
        #expect(pairs[0] == (42, 42))
    }

    @Test func `cyclic pairs of an empty sequence is empty`() {
        #expect([Int]().cyclicPairs().isEmpty)
    }
}

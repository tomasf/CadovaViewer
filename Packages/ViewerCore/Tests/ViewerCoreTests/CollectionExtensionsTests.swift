import Testing
@testable import ViewerCore

struct CollectionExtensionsTests {
    @Test func `safe subscript returns the element when the index is in bounds`() {
        let values = [10, 20, 30]
        #expect(values[safe: 0] == 10)
        #expect(values[safe: 2] == 30)
    }

    @Test func `safe subscript returns nil when the index is out of bounds`() {
        let values = [10, 20, 30]
        #expect(values[safe: 3] == nil)
        #expect(values[safe: -1] == nil)
        #expect([Int]()[safe: 0] == nil)
    }

    @Test func `async map preserves the original order`() async throws {
        let input = Array(0..<20)
        // Sleep longer for smaller values so completion order differs from input order.
        let result = try await input.asyncMap { value -> Int in
            try await Task.sleep(nanoseconds: UInt64((20 - value)) * 1_000_000)
            return value * value
        }
        #expect(result == input.map { $0 * $0 })
    }

    @Test func `async map of an empty collection is empty`() async throws {
        let result = await [Int]().asyncMap { $0 }
        #expect(result.isEmpty)
    }
}

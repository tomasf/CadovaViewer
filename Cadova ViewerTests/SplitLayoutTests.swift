import Testing
import Foundation
@testable import CadovaViewer

struct SplitLayoutTests {
    // A small tree:  split(root, h, A, split(inner, v, B, C))
    private let a = UUID(), b = UUID(), c = UUID()
    private let rootSplit = UUID(), innerSplit = UUID()

    private func sampleTree() -> SplitLayout {
        .split(id: rootSplit, axis: .horizontal,
               .leaf(a),
               .split(id: innerSplit, axis: .vertical, .leaf(b), .leaf(c)))
    }

    @Test func `leaf ids are listed left to right`() {
        #expect(sampleTree().leafIDs == [a, b, c])
        #expect(SplitLayout.leaf(a).leafIDs == [a])
    }

    @Test func `split ids list every split node`() {
        #expect(Set(sampleTree().splitIDs) == [rootSplit, innerSplit])
        #expect(SplitLayout.leaf(a).splitIDs.isEmpty)
    }

    @Test func `replacing a leaf swaps in the new subtree`() {
        let newSplit = UUID(), d = UUID()
        let replacement = SplitLayout.split(id: newSplit, axis: .vertical, .leaf(a), .leaf(d))
        let result = sampleTree().replacingLeaf(a, with: replacement)
        #expect(result.leafIDs == [a, d, b, c])
        #expect(Set(result.splitIDs) == [rootSplit, innerSplit, newSplit])
    }

    @Test func `replacing a missing leaf leaves the tree unchanged`() {
        let tree = sampleTree()
        #expect(tree.replacingLeaf(UUID(), with: .leaf(UUID())) == tree)
    }

    @Test func `removing a leaf collapses its parent into the sibling`() {
        // Removing B should replace the inner split with just C.
        let result = sampleTree().removingLeaf(b)
        #expect(result == .split(id: rootSplit, axis: .horizontal, .leaf(a), .leaf(c)))
    }

    @Test func `removing a top-level leaf promotes the sibling subtree`() {
        let result = sampleTree().removingLeaf(a)
        #expect(result == .split(id: innerSplit, axis: .vertical, .leaf(b), .leaf(c)))
    }

    @Test func `removing the only leaf returns nil`() {
        #expect(SplitLayout.leaf(a).removingLeaf(a) == nil)
    }

    @Test func `removing an absent leaf keeps every leaf`() {
        let tree = sampleTree()
        #expect(tree.removingLeaf(UUID())?.leafIDs == [a, b, c])
    }

    @Test func `split containing finds a leaf and its side`() {
        // A is the root split's first child; B and C are the inner split's children.
        #expect(sampleTree().split(containing: a)?.id == rootSplit)
        #expect(sampleTree().split(containing: a)?.closingIsFirst == true)
        #expect(sampleTree().split(containing: b)?.id == innerSplit)
        #expect(sampleTree().split(containing: b)?.closingIsFirst == true)
        #expect(sampleTree().split(containing: c)?.id == innerSplit)
        #expect(sampleTree().split(containing: c)?.closingIsFirst == false)
    }

    @Test func `split containing returns nil when the leaf is absent or alone`() {
        #expect(sampleTree().split(containing: UUID()) == nil)
        #expect(SplitLayout.leaf(a).split(containing: a) == nil)
    }

    @Test func `a layout survives a codable round trip`() throws {
        let tree = sampleTree()
        let data = try JSONEncoder().encode(tree)
        let decoded = try JSONDecoder().decode(SplitLayout.self, from: data)
        #expect(decoded == tree)
    }
}

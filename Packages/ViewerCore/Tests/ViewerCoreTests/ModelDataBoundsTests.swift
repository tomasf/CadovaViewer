import Testing
import SceneKit
@testable import ViewerCore

@MainActor
struct ModelDataBoundsTests {
    private func part(box size: SCNVector3, at position: SCNVector3, under root: SCNNode) -> ModelData.Part {
        var nodes = ModelData.Part.Nodes()
        nodes.model.geometry = SCNBox(width: CGFloat(size.x), height: CGFloat(size.y), length: CGFloat(size.z), chamferRadius: 0)
        nodes.container.position = position
        root.addChildNode(nodes.container)
        return ModelData.Part(nodes: nodes, itemIndex: 0, name: "Part", id: nil, semantic: .solid, stats: .init(vertexCount: 0, triangleCount: 0))
    }

    @Test func `part world bounding box includes the model root's unit scale`() throws {
        let root = SCNNode()
        root.scale = SCNVector3(25.4, 25.4, 25.4)
        let box = try #require(part(box: SCNVector3(2, 2, 2), at: SCNVector3(1, 0, 0), under: root).worldBoundingBox)

        #expect(box.min.x ≈ 0)
        #expect(box.max.x ≈ 50.8)
        #expect(box.size.y ≈ 50.8)
    }

    @Test func `part without geometry has no bounding box`() {
        let part = ModelData.Part(nodes: .init(), itemIndex: 0, name: "Empty", id: nil, semantic: .solid, stats: .init(vertexCount: 0, triangleCount: 0))
        #expect(part.worldBoundingBox == nil)
    }

    @Test func `union of parts spans all of them`() throws {
        let root = SCNNode()
        let parts = [
            part(box: SCNVector3(2, 2, 2), at: SCNVector3(-5, 0, 0), under: root),
            part(box: SCNVector3(2, 4, 2), at: SCNVector3(5, 0, 3), under: root),
        ]
        let box = try #require(ModelData.BoundingBox.union(of: parts))

        #expect(box.min.x ≈ -6)
        #expect(box.max.x ≈ 6)
        #expect(box.min.y ≈ -2)
        #expect(box.max.y ≈ 2)
        #expect(box.min.z ≈ -1)
        #expect(box.max.z ≈ 4)
        #expect(ModelData.BoundingBox.union(of: []) == nil)
    }

    @Test func `part number is nil when the item has none`() {
        let withNumber = ModelData.Part(nodes: .init(), itemIndex: 0, name: "A", id: "a-1", semantic: .solid, stats: .init(vertexCount: 0, triangleCount: 0))
        let without = ModelData.Part(nodes: .init(), itemIndex: 0, name: "B", id: nil, semantic: .solid, stats: .init(vertexCount: 0, triangleCount: 0))
        #expect(withNumber.partNumber == "a-1")
        #expect(without.partNumber == nil)
    }
}

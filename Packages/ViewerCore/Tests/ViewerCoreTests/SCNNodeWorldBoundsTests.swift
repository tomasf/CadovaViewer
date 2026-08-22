import Testing
import SceneKit
@testable import ViewerCore

@MainActor
struct SCNNodeWorldBoundsTests {
    @Test func `world bounding box includes root and child transforms`() {
        let root = SCNNode()
        root.scale = SCNVector3(10, 10, 10)

        let child = SCNNode(geometry: SCNBox(width: 2, height: 4, length: 6, chamferRadius: 0))
        child.position = SCNVector3(3, -2, 1)
        root.addChildNode(child)

        let box = root.worldBoundingBox()
        #expect(Double(box.min.x) ≈ 20)
        #expect(Double(box.max.x) ≈ 40)
        #expect(Double(box.min.y) ≈ -40)
        #expect(Double(box.max.y) ≈ 0)
        #expect(Double(box.min.z) ≈ -20)
        #expect(Double(box.max.z) ≈ 40)
    }

    @Test func `world bounding sphere is derived from world bounds`() {
        let root = SCNNode()
        let child = SCNNode(geometry: SCNBox(width: 2, height: 2, length: 2, chamferRadius: 0))
        child.position = SCNVector3(10, 0, 0)
        root.addChildNode(child)

        let sphere = root.worldBoundingSphere()
        #expect(Double(sphere.center.x) ≈ 10)
        #expect(Double(sphere.center.y) ≈ 0)
        #expect(Double(sphere.center.z) ≈ 0)
        #expect(Double(sphere.radius) ≈ Double(3).squareRoot())
    }
}

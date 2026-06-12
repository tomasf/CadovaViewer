import Testing
import SceneKit
@testable import ViewerCore

struct SCNVector3MathTests {
    @Test func `distance is the euclidean length between two points`() {
        let a = SCNVector3(1, 2, 3)
        let b = SCNVector3(4, 6, 3)
        #expect(a.distance(from: b) ≈ 5) // 3-4-5 triangle in the xy plane
    }

    @Test func `distance from a point to itself is zero`() {
        let p = SCNVector3(-7, 0.5, 12)
        #expect(p.distance(from: p) ≈ 0)
    }

    @Test func `equality compares all three components`() {
        #expect(SCNVector3(1, 2, 3) == SCNVector3(1, 2, 3))
        #expect(SCNVector3(1, 2, 3) != SCNVector3(1, 2, 3.0001))
        #expect(SCNVector3(1, 2, 3) != SCNVector3(1, 2.5, 3))
    }
}

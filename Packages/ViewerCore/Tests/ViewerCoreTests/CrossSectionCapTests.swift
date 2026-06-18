import Testing
import simd
import Manifold3D
@testable import ViewerCore

struct CrossSectionCapTests {
    // A Vector3/Vector2 to drive Manifold in the tests.
    struct V3: Vector3 { var x, y, z: Double; init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z } }

    /// Turns a Manifold into a `PartSolid` the way the loader would (indexed world-space mesh).
    private func solid(from manifold: Manifold<V3>) -> PartSolid {
        let mesh = manifold.meshGL()
        let vertices = mesh.vertices.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
        let indices = mesh.triangles.flatMap { [UInt32($0.a), UInt32($0.b), UInt32($0.c)] }
        return PartSolid(vertices: vertices, indices: indices)
    }

    private func triangleArea(_ tris: [SIMD3<Float>]) -> Double {
        var area = 0.0
        var i = 0
        while i + 2 < tris.count {
            let a = SIMD3<Double>(tris[i]), b = SIMD3<Double>(tris[i + 1]), c = SIMD3<Double>(tris[i + 2])
            area += Double(simd_length(simd_cross(b - a, c - a))) / 2
            i += 3
        }
        return area
    }

    @Test func `cutting a cube through the middle caps with a square of the right area`() {
        let cube: Manifold<V3> = .cube(size: V3(x: 2, y: 2, z: 2), center: true)
        let cap = solid(from: cube).capTriangles(planeNormal: SIMD3(0, 0, 1), offset: 0)

        #expect(!cap.isEmpty)
        #expect(abs(triangleArea(cap) - 4) < 1e-3)       // 2×2 square
        #expect(cap.allSatisfy { abs($0.z) < 1e-4 })     // lies on z = 0
    }

    @Test func `a plane that misses the solid produces no cap`() {
        let cube: Manifold<V3> = .cube(size: V3(x: 2, y: 2, z: 2), center: true)
        let cap = solid(from: cube).capTriangles(planeNormal: SIMD3(0, 0, 1), offset: 5)
        #expect(cap.isEmpty)
    }

    @Test func `cutting along X works off-center`() {
        let cube: Manifold<V3> = .cube(size: V3(x: 4, y: 4, z: 4), center: true)
        let cap = solid(from: cube).capTriangles(planeNormal: SIMD3(1, 0, 0), offset: 1)
        #expect(abs(triangleArea(cap) - 16) < 1e-3)      // 4×4 square
        #expect(cap.allSatisfy { abs($0.x - 1) < 1e-4 }) // lies on x = 1
    }

    @Test func `a tilted plane caps correctly and lies on the plane`() {
        let cube: Manifold<V3> = .cube(size: V3(x: 2, y: 2, z: 2), center: true)
        let normal = simd_normalize(SIMD3<Double>(1, 1, 0))
        let cap = solid(from: cube).capTriangles(planeNormal: normal, offset: 0)

        #expect(!cap.isEmpty)
        // The cross-section of a 2-cube by x+y=0 is a 2√2 × 2 rectangle → area 4√2.
        #expect(abs(triangleArea(cap) - 4 * 2.0.squareRoot()) < 1e-3)
        // Every vertex lies on the plane dot(v, n) = 0.
        #expect(cap.allSatisfy { abs(simd_dot(SIMD3<Double>($0), normal)) < 1e-4 })
    }

    @Test func `a hole is subtracted from the cap (tube caps as an annulus)`() {
        let outer: Manifold<V3> = .cube(size: V3(x: 4, y: 4, z: 4), center: true)
        let inner: Manifold<V3> = .cube(size: V3(x: 2, y: 2, z: 10), center: true)
        let tube = outer.boolean(.difference, with: inner)

        let cap = solid(from: tube).capTriangles(planeNormal: SIMD3(0, 0, 1), offset: 0)
        #expect(!cap.isEmpty)
        // Annulus area = 4×4 − 2×2 = 12 (the hole is NOT filled).
        #expect(abs(triangleArea(cap) - 12) < 1e-3)
    }
}

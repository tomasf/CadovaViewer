import Testing
import simd
import ThreeMF
@testable import ViewerCore

struct MeshMetricsTests {
    /// Axis-aligned unit cube from (0,0,0) to (1,1,1), 12 triangles with consistent outward
    /// winding so the signed-volume sum is positive.
    private func unitCube() -> Mesh {
        let v = [
            (0.0, 0.0, 0.0), (1.0, 0.0, 0.0), (1.0, 1.0, 0.0), (0.0, 1.0, 0.0),
            (0.0, 0.0, 1.0), (1.0, 0.0, 1.0), (1.0, 1.0, 1.0), (0.0, 1.0, 1.0)
        ].map { Mesh.Vertex(x: $0.0, y: $0.1, z: $0.2) }

        let faces = [
            (0, 2, 1), (0, 3, 2), // bottom (−Z)
            (4, 5, 6), (4, 6, 7), // top (+Z)
            (0, 1, 5), (0, 5, 4), // front (−Y)
            (2, 3, 7), (2, 7, 6), // back (+Y)
            (0, 4, 7), (0, 7, 3), // left (−X)
            (1, 2, 6), (1, 6, 5)  // right (+X)
        ]
        let triangles = faces.map { Mesh.Triangle(v1: $0.0, v2: $0.1, v3: $0.2, propertyIndex: nil) }
        return Mesh(vertices: v, triangles: triangles)
    }

    @Test func `unit cube has area 6 and volume 1`() {
        let (area, volume) = unitCube().areaAndVolume(transform: matrix_identity_double4x4)
        #expect(area ≈ 6)
        #expect(volume ≈ 1)
    }

    @Test func `scaling the transform scales area and volume`() {
        let scale = simd_double4x4(diagonal: SIMD4(2, 2, 2, 1))
        let (area, volume) = unitCube().areaAndVolume(transform: scale)
        #expect(area ≈ 24)  // area scales with s²
        #expect(volume ≈ 8) // volume scales with s³
    }

    @Test func `translation leaves area and volume unchanged`() {
        var translate = matrix_identity_double4x4
        translate.columns.3 = SIMD4(10, -5, 3, 1)
        let (area, volume) = unitCube().areaAndVolume(transform: translate)
        #expect(area ≈ 6)
        #expect(volume ≈ 1)
    }
}

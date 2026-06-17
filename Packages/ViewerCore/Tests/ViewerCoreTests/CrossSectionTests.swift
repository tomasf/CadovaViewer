import Testing
import simd
@testable import ViewerCore

struct CrossSectionTests {
    /// A fragment is kept when `dot(position, normal) <= distance`.
    private func keeps(_ section: CrossSection, _ point: SIMD3<Double>) -> Bool {
        let plane = section.plane()
        return simd_dot(point, SIMD3(plane.x, plane.y, plane.z)) <= plane.w
    }

    @Test func `unflipped plane keeps the low side of the axis`() {
        let section = CrossSection(axis: .x, offset: 5, flipped: false)
        #expect(keeps(section, SIMD3(4, 0, 0)))   // below the plane → kept
        #expect(!keeps(section, SIMD3(6, 0, 0)))  // above the plane → cut away
    }

    @Test func `flipped plane keeps the high side of the axis`() {
        let section = CrossSection(axis: .x, offset: 5, flipped: true)
        #expect(!keeps(section, SIMD3(4, 0, 0))) // below the plane → cut away
        #expect(keeps(section, SIMD3(6, 0, 0)))  // above the plane → kept
    }

    @Test func `plane normal follows the chosen axis`() {
        #expect(CrossSection(axis: .x).plane().xyz == SIMD3(1, 0, 0))
        #expect(CrossSection(axis: .y).plane().xyz == SIMD3(0, 1, 0))
        #expect(CrossSection(axis: .z).plane().xyz == SIMD3(0, 0, 1))
        #expect(CrossSection(axis: .z, flipped: true).plane().xyz == SIMD3(0, 0, -1))
    }

    @Test func `offset range spans the box extent along the axis and ignores flip`() {
        let boxMin = SIMD3<Double>(-10, -20, -30)
        let boxMax = SIMD3<Double>(10, 20, 30)

        #expect(CrossSection(axis: .x).offsetRange(boxMin: boxMin, boxMax: boxMax) == -10...10)
        #expect(CrossSection(axis: .y).offsetRange(boxMin: boxMin, boxMax: boxMax) == -20...20)
        #expect(CrossSection(axis: .z, flipped: true).offsetRange(boxMin: boxMin, boxMax: boxMax) == -30...30)
    }
}

private extension SIMD4 where Scalar == Double {
    var xyz: SIMD3<Double> { SIMD3(x, y, z) }
}

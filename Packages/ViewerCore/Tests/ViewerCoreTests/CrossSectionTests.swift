import Testing
import Foundation
import simd
@testable import ViewerCore

struct CrossSectionTests {
    private func keeps(_ section: CrossSection, _ point: SIMD3<Double>) -> Bool {
        let plane = section.plane()
        return simd_dot(point, SIMD3(plane.x, plane.y, plane.z)) <= plane.w
    }

    private func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Bool {
        simd_length(a - b) < 1e-3
    }

    @Test func `an axis-aligned section's normal points along that axis`() {
        #expect(close(CrossSection.axisAligned(.x, origin: .zero).normal, SIMD3(1, 0, 0)))
        #expect(close(CrossSection.axisAligned(.y, origin: .zero).normal, SIMD3(0, 1, 0)))
        #expect(close(CrossSection.axisAligned(.z, origin: .zero).normal, SIMD3(0, 0, 1)))
    }

    @Test func `the plane distance is the normal projected onto the origin`() {
        let section = CrossSection.axisAligned(.x, origin: SIMD3(5, 99, -99))
        let plane = section.plane()
        #expect(plane.w ≈ 5) // distance along +X
        #expect(keeps(section, SIMD3(4, 0, 0)))   // below the plane → kept
        #expect(!keeps(section, SIMD3(6, 0, 0)))  // above the plane → cut away
    }

    @Test func `flipping keeps the other half`() {
        var section = CrossSection.axisAligned(.x, origin: SIMD3(5, 0, 0))
        section.flip()
        #expect(close(section.normal, SIMD3(-1, 0, 0)))
        #expect(keeps(section, SIMD3(6, 0, 0)))   // now the high side is kept
        #expect(!keeps(section, SIMD3(4, 0, 0)))
        // The plane still passes through the same origin after flipping.
        #expect(section.plane().w ≈ -5)
    }

    @Test func `hides reports the cut-away side and keeps points on the plane`() {
        let section = CrossSection.axisAligned(.x, origin: SIMD3(5, 0, 0)) // keeps x <= 5
        #expect(section.hides(SIMD3(6, 0, 0)))   // past the plane → hidden
        #expect(!section.hides(SIMD3(4, 0, 0)))  // kept side → visible
        #expect(!section.hides(SIMD3(5, 9, -9))) // exactly on the plane → visible (tolerance)
        var flipped = section
        flipped.flip()
        #expect(flipped.hides(SIMD3(4, 0, 0)))
        #expect(!flipped.hides(SIMD3(6, 0, 0)))
    }

    @Test func `a section survives a Codable round-trip`() throws {
        let tilt = simd_quatd(angle: .pi / 3, axis: simd_normalize(SIMD3(0.2, 1, -0.5)))
        let original = CrossSection(origin: SIMD3(3, -2, 7), orientation: tilt, enabled: false, colorIndex: 4)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CrossSection.self, from: data)
        #expect(decoded == original)
        #expect(close(decoded.normal, original.normal))
    }

    @Test func `snapping to the nearest axis aligns the normal and keeps the origin and side`() {
        let origin = SIMD3<Double>(3, -2, 7)

        // A slight tilt off +Z snaps to +Z, keeping the origin.
        var nearZ = CrossSection(origin: origin, orientation: simd_quatd(angle: 0.15, axis: simd_normalize(SIMD3(1, 0.3, 0))))
        nearZ.snapToNearestAxis()
        #expect(close(nearZ.normal, SIMD3(0, 0, 1)))
        #expect(nearZ.origin == origin)

        // A normal leaning toward −X snaps to −X (the kept side is preserved), not +X.
        var nearNegX = CrossSection(origin: origin, orientation: simd_quatd(from: SIMD3(0, 0, 1), to: simd_normalize(SIMD3(-1, 0.2, 0.1))))
        nearNegX.snapToNearestAxis()
        #expect(close(nearNegX.normal, SIMD3(-1, 0, 0)))

        // The antiparallel case (toward −Z) is handled without producing NaNs.
        var nearNegZ = CrossSection(origin: origin, orientation: simd_quatd(from: SIMD3(0, 0, 1), to: simd_normalize(SIMD3(0.1, 0.1, -1))))
        nearNegZ.snapToNearestAxis()
        #expect(close(nearNegZ.normal, SIMD3(0, 0, -1)))
    }

    @Test func `a tilted section has a unit normal and passes through its origin`() {
        let origin = SIMD3<Double>(3, -2, 7)
        let tilt = simd_quatd(angle: .pi / 4, axis: simd_normalize(SIMD3(1, 1, 0)))
        let section = CrossSection(origin: origin, orientation: tilt)
        #expect(simd_length(section.normal) ≈ 1)
        // The origin lies exactly on the plane: dot(origin, n) == distance.
        let plane = section.plane()
        #expect(simd_dot(origin, SIMD3(plane.x, plane.y, plane.z)) ≈ plane.w)
    }
}

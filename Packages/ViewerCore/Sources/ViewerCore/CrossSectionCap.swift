import Foundation
import simd
import Manifold3D

/// A part's solid geometry, used to compute the filled "cap" where a cutting plane slices it.
///
/// Backed by the Manifold library: the part's indexed mesh is turned into a `Manifold` once (lazily,
/// then cached), and each cap is a true planar cross-section of that solid — so holes are subtracted
/// correctly (a tube caps as an annulus, not a filled disc). 3MF meshes are watertight by
/// definition, which is what Manifold requires; a mesh it can't ingest simply yields no cap.
public final class PartSolid: @unchecked Sendable {
    private let vertices: [SIMD3<Float>]
    private let indices: [UInt32]

    /// Serialises lazy construction and slicing — Manifold's C++ objects aren't guaranteed
    /// thread-safe, and multiple viewports compute caps on their own queues.
    private let lock = NSLock()
    private var didBuild = false
    private var manifold: Manifold<CapVector3>?

    /// The base manifold pre-rotated so a given cut normal lands on +Z, cached so that dragging the
    /// offset (which keeps the normal fixed) reuses it — and the spatial structure Manifold builds on
    /// the first slice — instead of re-rotating the whole solid every slice.
    private var cachedNormal: SIMD3<Double>?
    private var rotatedManifold: Manifold<CapVector3>?
    private var inverseRotation: simd_double3x3 = matrix_identity_double3x3

    /// - Parameters:
    ///   - vertices: World-space (millimetre) vertex positions.
    ///   - indices: Triangle vertex indices into `vertices` (length a multiple of three).
    public init(vertices: [SIMD3<Float>], indices: [UInt32]) {
        self.vertices = vertices
        self.indices = indices
    }

    /// The cap triangles where the plane `dot(p, planeNormal) == offset` slices this solid, as a
    /// world-space triangle soup. Empty if the plane misses the solid or the mesh isn't manifold.
    /// `planeNormal` should be a unit vector; the cap is independent of which side is kept.
    public func capTriangles(planeNormal: SIMD3<Double>, offset: Double) -> [SIMD3<Float>] {
        lock.lock()
        defer { lock.unlock() }

        guard let rotated = rotatedManifold(forNormal: planeNormal) else { return [] }

        // Manifold slices at a Z height; the cached `rotated` solid already has the cut normal on +Z,
        // so slice there and map the 2D section back into world space with the inverse rotation.
        let section: Manifold3D.CrossSection<CapVector2> = rotated.slice(at: offset)

        let polygons: [Polygon<CapVector2>] = section.polygons()
        guard !polygons.isEmpty else { return [] }
        let combinedVertices = polygons.flatMap { $0.vertices }
        let triangles = Polygon<CapVector2>.triangulate(polygons, epsilon: 1e-6)

        var result: [SIMD3<Float>] = []
        result.reserveCapacity(triangles.count * 3)
        for triangle in triangles {
            for index in [triangle.a, triangle.b, triangle.c] {
                let vertex = combinedVertices[index]
                let world = inverseRotation * SIMD3<Double>(vertex.x, vertex.y, offset)
                result.append(SIMD3<Float>(Float(world.x), Float(world.y), Float(world.z)))
            }
        }
        return result
    }

    /// The base manifold rotated to bring `normal` onto +Z, caching it (and `inverseRotation`) so a
    /// drag at a fixed axis doesn't re-rotate the solid each slice. Caller must hold `lock`.
    private func rotatedManifold(forNormal normal: SIMD3<Double>) -> Manifold<CapVector3>? {
        if cachedNormal == normal, let rotatedManifold { return rotatedManifold }
        guard let manifold = buildIfNeeded() else { return nil }
        let rotation = simd_double3x3(simd_quatd(from: normal, to: SIMD3(0, 0, 1)))
        let rotated = manifold.transform(RotationMatrix(rotation))
        rotatedManifold = rotated
        inverseRotation = rotation.transpose
        cachedNormal = normal
        return rotated
    }

    /// Builds and caches the `Manifold` on first use. Caller must hold `lock`.
    private func buildIfNeeded() -> Manifold<CapVector3>? {
        if didBuild { return manifold }
        didBuild = true
        guard !indices.isEmpty else { return nil }

        let meshVertices = vertices.map { CapVector3(x: Double($0.x), y: Double($0.y), z: Double($0.z)) }
        var meshTriangles: [Triangle] = []
        meshTriangles.reserveCapacity(indices.count / 3)
        var i = 0
        while i + 2 < indices.count {
            meshTriangles.append(Triangle(Int(indices[i]), Int(indices[i + 1]), Int(indices[i + 2])))
            i += 3
        }
        manifold = try? Manifold(MeshGL(vertices: meshVertices, triangles: meshTriangles))
        return manifold
    }
}

/// Minimal vector/matrix types conforming to Manifold's generic protocols.
struct CapVector3: Vector3 {
    var x, y, z: Double
    init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
}

struct CapVector2: Vector2 {
    var x, y: Double
    init(x: Double, y: Double) { self.x = x; self.y = y }
}

/// A pure rotation as a 3×4 affine transform (no translation) for `Manifold.transform(_:)`.
struct RotationMatrix: Matrix3x4 {
    let rotation: simd_double3x3
    init(_ rotation: simd_double3x3) { self.rotation = rotation }
    subscript(_ row: Int, _ column: Int) -> Double {
        column < 3 ? rotation[column][row] : 0
    }
}

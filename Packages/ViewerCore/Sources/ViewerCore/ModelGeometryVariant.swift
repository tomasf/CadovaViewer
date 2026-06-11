import Foundation
import ThreeMF
import SceneKit

/// Owns a main-geometry node and lazily produces a smooth-shaded copy of its geometry.
///
/// The flat geometry (no normal source — SceneKit shades it faceted) is built at load time.
/// The smooth variant is only computed the first time it's requested, then cached; the
/// retained mesh is released afterwards. Computing it can be done off the main thread.
public final class ModelGeometryVariant: @unchecked Sendable {
    public let node: SCNNode
    public let flat: SCNGeometry

    private var mesh: ThreeMF.Mesh?
    private var emittedCorners: [Int32]?
    private var cachedSmooth: SCNGeometry?

    init(node: SCNNode, flat: SCNGeometry, mesh: ThreeMF.Mesh, emittedCorners: [Int32]) {
        self.node = node
        self.flat = flat
        self.mesh = mesh
        self.emittedCorners = emittedCorners
    }

    /// The smooth geometry if it has already been built, without building it. Lets a caller apply
    /// smooth shading on the main thread without risking a synchronous build (fall back to `flat`
    /// and swap in the smooth geometry once a background build completes).
    public var smoothIfAvailable: SCNGeometry? { cachedSmooth }

    /// The smooth-shaded geometry, built once and cached. Shares the flat geometry's
    /// vertex/colour sources, elements and materials, adding only a normal source.
    public func smoothGeometry() -> SCNGeometry {
        if let cachedSmooth { return cachedSmooth }
        guard let mesh, let emittedCorners else { return flat }

        let cornerNormals = mesh.smoothCornerNormals()
        var normals: [SCNVector3] = []
        normals.reserveCapacity(emittedCorners.count)
        for packed in emittedCorners {
            normals.append(cornerNormals[Int(packed)])
        }

        let normalSource = SCNGeometrySource(normals: normals)
        let smooth = SCNGeometry(sources: flat.sources + [normalSource], elements: flat.elements)
        smooth.materials = flat.materials
        smooth.name = flat.name

        cachedSmooth = smooth
        self.mesh = nil
        self.emittedCorners = nil
        return smooth
    }
}

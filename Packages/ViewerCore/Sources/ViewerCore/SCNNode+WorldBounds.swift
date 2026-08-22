import SceneKit
import simd

extension SCNNode {
    public typealias BoundingBox = (min: SCNVector3, max: SCNVector3)

    /// Axis-aligned bounds for all geometry below this node, expressed in scene/world coordinates.
    ///
    /// `SCNNode.boundingBox` is local to the node it is read from. That is useful for geometry work,
    /// but camera navigation and hit-test fallback points need the coordinates SceneKit renders in,
    /// including any transform on the root node or component containers.
    public func worldBoundingBox() -> BoundingBox {
        var result: (min: SIMD3<Float>, max: SIMD3<Float>)?

        enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let (localMin, localMax) = node.boundingBox
            let corners = [
                SIMD3(Float(localMin.x), Float(localMin.y), Float(localMin.z)),
                SIMD3(Float(localMin.x), Float(localMin.y), Float(localMax.z)),
                SIMD3(Float(localMin.x), Float(localMax.y), Float(localMin.z)),
                SIMD3(Float(localMin.x), Float(localMax.y), Float(localMax.z)),
                SIMD3(Float(localMax.x), Float(localMin.y), Float(localMin.z)),
                SIMD3(Float(localMax.x), Float(localMin.y), Float(localMax.z)),
                SIMD3(Float(localMax.x), Float(localMax.y), Float(localMin.z)),
                SIMD3(Float(localMax.x), Float(localMax.y), Float(localMax.z))
            ]
            let transform = node.simdWorldTransform
            for corner in corners {
                let world = (transform * SIMD4<Float>(corner, 1)).xyz
                if result == nil {
                    result = (world, world)
                } else {
                    result!.min = simd_min(result!.min, world)
                    result!.max = simd_max(result!.max, world)
                }
            }
        }

        guard let box = result else { return (SCNVector3Zero, SCNVector3Zero) }
        return (SCNVector3(box.min), SCNVector3(box.max))
    }

    public func worldBoundingSphere() -> (center: SCNVector3, radius: Float) {
        let box = worldBoundingBox()
        let min = SIMD3<Float>(box.min)
        let max = SIMD3<Float>(box.max)
        let center = (min + max) / 2
        return (SCNVector3(center), simd_distance(min, max) / 2)
    }
}

private extension SIMD4<Float> {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}

import SceneKit

extension SCNGeometry {
    /// Replaces all materials with `materials`, in order.
    func setMaterials(_ materials: [SCNMaterial]) {
        for _ in (0..<materials.count) { removeMaterial(at: 0) }

        for (index, material) in materials.enumerated() {
            insertMaterial(material, at: index)
        }
    }
}

import SceneKit
import ModelIO
import SwiftUI
import ViewerCore

extension SCNSceneRenderer {
    /// Requests an on-demand redraw. The view renders only when its scene time changes, so
    /// nudging `sceneTime` by a hair marks it dirty without visibly advancing any animation.
    func setNeedsRedraw() {
        sceneTime += 0.00001
    }
}

extension SCNDebugOptions {
    static let showWorldOrigin = Self(rawValue: 4096)
}

extension SCNGeometry {
    func setMaterials(_ materials: [SCNMaterial]) {
        for _ in (0..<materials.count) { removeMaterial(at: 0) }

        for (index, material) in materials.enumerated() {
            insertMaterial(material, at: index)
        }
    }
}

extension SIMD4<Float> {
    var xyz: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }
}

extension SCNMatrix4 {
    struct CodingWrapper: Codable {
        let columns: [[Double]]

        init(_ matrix: SCNMatrix4) {
            let simdMatrix = matrix_double4x4(matrix)
            columns = (0..<4).map { a in
                (0..<4).map { b in
                    simdMatrix[a][b]
                }
            }
        }

        var scnMatrix4: SCNMatrix4 {
            var simdMatrix = matrix_double4x4()
            for a in 0..<4 {
                for b in 0..<4 {
                    simdMatrix[a][b] = columns[a][b]
                }
            }
            return SCNMatrix4(simdMatrix)
        }
    }
}


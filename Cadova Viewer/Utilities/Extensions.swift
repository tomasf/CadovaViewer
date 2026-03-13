import SceneKit
import ModelIO
import SwiftUI

extension SCNSceneRenderer {
    func render() {
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

extension Sequence {
    func unwrap<A, B>() -> ([A], [B]) where Element == (A, B) {
        reduce(into: ([], [])) {
            $0.0.append($1.0)
            $0.1.append($1.1)
        }
    }

    func unwrap<A, B, C>() -> ([A], [B], [C]) where Element == (A, B, C) {
        reduce(into: ([], [], [])) {
            $0.0.append($1.0)
            $0.1.append($1.1)
            $0.2.append($1.2)
        }
    }

    func unwrap<A, B, C, D>() -> ([A], [B], [C], [D]) where Element == (A, B, C, D) {
        reduce(into: ([], [], [], [])) {
            $0.0.append($1.0)
            $0.1.append($1.1)
            $0.2.append($1.2)
            $0.3.append($1.3)
        }
    }

    func paired() -> [(Element, Element)] {
        .init(zip(self, dropFirst()))
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

extension MTLRenderCommandEncoder {
    func setLineWidthPrivate(_ width: Float) {
        guard let self = self as? NSObject,
              self.responds(to: NSSelectorFromString("setLineWidth:"))
        else { return }

        self.setValue(width, forKey: "lineWidth")
    }
}

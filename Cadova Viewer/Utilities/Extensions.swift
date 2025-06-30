import SceneKit
import ModelIO
import SwiftUI

extension SCNVector3: @retroactive Equatable {
    public static func == (lhs: SCNVector3, rhs: SCNVector3) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y && lhs.z == rhs.z
    }

    func distance(from other: SCNVector3) -> Double {
        sqrt((x - other.x).magnitudeSquared + (y - other.y).magnitudeSquared + (z - other.z).magnitudeSquared)
    }
}

extension SCNSceneRenderer {
    func xyPlanePoint(forViewPoint point: CGPoint) -> SCNVector3 {
        let rayStart = unprojectPoint(SCNVector3(point.x, point.y, 0))
        let rayEnd = unprojectPoint(SCNVector3(point.x, point.y, 1))

        let t = -rayStart.z / (rayEnd.z - rayStart.z)
        return SCNVector3(
            rayStart.x + t * (rayEnd.x - rayStart.x),
            rayStart.y + t * (rayEnd.y - rayStart.y),
            0
        )
    }

    func render() {
        sceneTime += 0.00001
    }
}

extension SCNDebugOptions {
    static let showWorldOrigin = Self(rawValue: 4096)
}

extension SCNGeometry {
    static func lines(_ segments: [(SCNVector3, SCNVector3)], color: NSColor) -> SCNGeometry {
        let element = SCNGeometryElement(indices: (0..<segments.count*2).map(Int32.init), primitiveType: .line)
        let points = segments.flatMap { [$0, $1] }
        let lineGeo = SCNGeometry(sources: [.init(vertices: points)], elements: [element])
        lineGeo.firstMaterial?.lightingModel = .constant
        lineGeo.firstMaterial?.diffuse.contents = color
        return lineGeo
    }

    func setMaterials(_ materials: [SCNMaterial]) {
        for _ in (0..<materials.count) { removeMaterial(at: 0) }

        for (index, material) in materials.enumerated() {
            insertMaterial(material, at: index)
        }
    }
}

extension SCNGeometrySource {
    static func colors(_ array: [SCNVector4]) -> Self {
        array.withUnsafeBufferPointer { bufferPointer in
            Self(
                data: Data(buffer: bufferPointer),
                semantic: .color,
                vectorCount: array.count,
                usesFloatComponents: true,
                componentsPerVector: 4,
                bytesPerComponent: MemoryLayout<CGFloat>.size,
                dataOffset: 0,
                dataStride: MemoryLayout<SCNVector4>.stride
            )
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

    func wrappedPairs() -> [(Element, Element)] {
        .init(zip(self, dropFirst() + Array(prefix(1))))
    }
}

internal extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension SIMD4<Float> {
    var xyz: SIMD3<Float> {
        SIMD3<Float>(x, y, z)
    }
}

extension SCNNode {
    var treeCategoryBitMask: Int {
        get { categoryBitMask }
        set {
            enumerateHierarchy { node, _ in
                node.categoryBitMask = newValue
            }
        }
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

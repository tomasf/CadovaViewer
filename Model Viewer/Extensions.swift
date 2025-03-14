import SceneKit
import ModelIO

extension SCNVector3 {
    func distance(from other: SCNVector3) -> Double {
        sqrt((x - other.x).magnitudeSquared + (y - other.y).magnitudeSquared + (z - other.z).magnitudeSquared)
    }
}

extension SCNView {
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

    func gridScale(at viewPoint: CGPoint) -> Double {
        let gridCenter = xyPlanePoint(forViewPoint: viewPoint)
        let gridNeighbor = SCNVector3(gridCenter.x + 1, gridCenter.y + 1, 0)

        let projectedCenter = projectPoint(gridCenter)
        let projectedNeighbor = projectPoint(gridNeighbor)
        return projectedCenter.distance(from: projectedNeighbor) / 2.squareRoot()
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

    func removingNormals() -> (SCNGeometry, SCNGeometrySource?) {
        let existingNormals = sources.first(where: { $0.semantic == .normal })
        let newSources = sources.filter { $0.semantic != .normal }
        let geometry = SCNGeometry(sources: newSources, elements: elements)
        geometry.name = self.name
        geometry.materials = self.materials
        return (geometry, existingNormals)
    }

    func replacingNormals(_ with: SCNGeometrySource?) -> SCNGeometry {
        let newSources = sources.filter { $0.semantic != .normal } + (with.map { [$0] } ?? [])
        let geometry = SCNGeometry(sources: newSources, elements: elements)
        geometry.materials = self.materials
        geometry.name = self.name
        return geometry
    }

    func calculatingNormals() -> SCNGeometry {
        guard (elements.first?.primitiveCount ?? 0) > 0 else { return self }
        let mesh = MDLMesh(scnGeometry: self)
        mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.9)
        let geometry = SCNGeometry(mdlMesh: mesh)
        geometry.name = self.name
        geometry.materials = self.materials
        return geometry
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
}

internal extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

import SceneKit
import AppKit
import Metal

// MARK: - SCNVector3 Extensions

extension SCNVector3: @retroactive Equatable {
    public static func == (lhs: SCNVector3, rhs: SCNVector3) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y && lhs.z == rhs.z
    }

    public func distance(from other: SCNVector3) -> Double {
        sqrt((x - other.x).magnitudeSquared + (y - other.y).magnitudeSquared + (z - other.z).magnitudeSquared)
    }
}

// MARK: - SCNSceneRenderer Extensions

extension SCNSceneRenderer {
    public func xyPlanePoint(forViewPoint point: CGPoint) -> SCNVector3 {
        let rayStart = unprojectPoint(SCNVector3(point.x, point.y, 0))
        let rayEnd = unprojectPoint(SCNVector3(point.x, point.y, 1))

        let t = -rayStart.z / (rayEnd.z - rayStart.z)
        return SCNVector3(
            rayStart.x + t * (rayEnd.x - rayStart.x),
            rayStart.y + t * (rayEnd.y - rayStart.y),
            0
        )
    }
}

// MARK: - SCNGeometry Extensions

extension SCNGeometry {
    public static func lines(_ segments: [(SCNVector3, SCNVector3)], color: NSColor) -> SCNGeometry {
        let element = SCNGeometryElement(indices: (0..<segments.count*2).map(Int32.init), primitiveType: .line)
        let points = segments.flatMap { [$0, $1] }
        let lineGeo = SCNGeometry(sources: [.init(vertices: points)], elements: [element])
        lineGeo.firstMaterial?.lightingModel = .constant
        lineGeo.firstMaterial?.diffuse.contents = color
        return lineGeo
    }
}

// MARK: - SCNNode Extensions

extension SCNNode {
    public var treeCategoryBitMask: Int {
        get { categoryBitMask }
        set {
            enumerateHierarchy { node, _ in
                node.categoryBitMask = newValue
            }
        }
    }
}

// MARK: - Sequence Extensions

extension Sequence {
    public func wrappedPairs() -> [(Element, Element)] {
        .init(zip(self, dropFirst() + Array(prefix(1))))
    }
}

// MARK: - SCNGeometrySource Extensions

extension SCNGeometrySource {
    public static func colors(_ array: [SCNVector4]) -> Self {
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

extension Collection where Element: Sendable {
    public func asyncMap<T: Sendable>(_ transform: @Sendable @escaping (Element) async throws -> T) async rethrows -> [T] {
        try await withThrowingTaskGroup(of: (Int, T).self) { group in
            for (index, element) in self.enumerated() {
                group.addTask {
                    let value = try await transform(element)
                    return (index, value)
                }
            }

            var results = Array<T?>(repeating: nil, count: self.count)
            for try await (index, result) in group {
                results[index] = result
            }

            return results.map { $0! }
        }
    }
}

extension Collection {
    public subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - SCNView Extensions

extension SCNView {
    public func applyEdgeDepthOffset(edgeNodes: [SCNNode], cameraNode: SCNNode, modelNode: SCNNode, viewSize: CGSize) {
        // Clear last frame's offset first so the edges sit on the surface during hit
        // testing. The closest hit is then either the surface or a coincident edge — same
        // distance either way — so we can use the cheap closest-hit search without sorting
        // every intersection (`.all`) or filtering edges out.
        for node in edgeNodes {
            node.simdPosition = .zero
        }

        let hitTestPoints: [CGPoint] = [
            CGPoint(x: viewSize.width / 2, y: viewSize.height / 2),
            CGPoint(x: 0, y: 0),
            CGPoint(x: viewSize.width, y: 0),
            CGPoint(x: viewSize.width, y: viewSize.height),
            CGPoint(x: 0, y: viewSize.height),
        ]
        var closestHitTestDistance: Float = 1000.0
        for viewPoint in hitTestPoints {
            let hit = hitTest(viewPoint, options: [
                .searchMode: SCNHitTestSearchMode.closest.rawValue as NSNumber,
                .rootNode: modelNode
            ]).first
            if let hit {
                closestHitTestDistance = min(
                    Float(hit.worldCoordinates.distance(from: cameraNode.presentation.worldPosition)),
                    closestHitTestDistance
                )
            }
        }
        for node in edgeNodes {
            let distanceToPart = Float(cameraNode.presentation.worldPosition.distance(from: node.worldPosition))
            let minDistance = min(closestHitTestDistance, distanceToPart)
            node.simdWorldPosition += cameraNode.presentation.simdWorldFront * (minDistance / -1000.0)
        }
    }
}

// MARK: - MTLRenderCommandEncoder Extensions

extension MTLRenderCommandEncoder {
    public func setLineWidthPrivate(_ width: Float) {
        guard let self = self as? NSObject,
              self.responds(to: NSSelectorFromString("setLineWidth:"))
        else { return }

        self.setValue(width, forKey: "lineWidth")
    }
}

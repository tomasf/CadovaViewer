import Foundation
import ThreeMF
import SceneKit
import AppKit

public struct ModelData: Sendable {
    public let rootNode: SCNNode
    public let parts: [Part]
    public let metadata: [ThreeMF.Metadata]

    public init(rootNode: SCNNode, parts: [Part], metadata: [ThreeMF.Metadata]) {
        self.rootNode = rootNode
        self.parts = parts
        self.metadata = metadata
    }

    public init() {
        self.init(rootNode: .init(), parts: [], metadata: [])
    }

    public struct Part: Identifiable, Sendable {
        public typealias ID = String

        public let nodes: Nodes
        public let name: String
        public let id: ID
        public let semantic: PartSemantic
        public let statistics: Statistics

        /// One per main-geometry node, used to swap each node between its flat geometry and a
        /// lazily-built smooth-shaded variant. Empty when smooth shading isn't applicable.
        public let modelGeometryVariants: [ModelGeometryVariant]

        public init(nodes: Nodes, name: String, id: ID?, semantic: PartSemantic, stats: Statistics, modelGeometryVariants: [ModelGeometryVariant] = []) {
            self.nodes = nodes
            self.name = name
            self.id = id ?? UUID().uuidString
            self.semantic = semantic
            self.statistics = stats
            self.modelGeometryVariants = modelGeometryVariants
        }

        public struct Nodes: Sendable {
            public var container: SCNNode
            public var model: SCNNode
            public var sharpEdges: SCNNode?
            public var smoothEdges: SCNNode?

            public init() {
                container = SCNNode()
                model = SCNNode()
                container.addChildNode(model)
            }
        }
    }

    public var statistics: Statistics {
        .init(parts.map(\.statistics))
    }
}

extension ModelData {
    public struct Statistics: Sendable {
        public let vertexCount: Int
        public let triangleCount: Int

        public init(vertexCount: Int, triangleCount: Int) {
            self.vertexCount = vertexCount
            self.triangleCount = triangleCount
        }

        public init(_ stats: [Statistics]) {
            self.init(
                vertexCount: stats.map(\.vertexCount).reduce(0, +),
                triangleCount: stats.map(\.triangleCount).reduce(0, +)
            )
        }
    }
}

extension ModelData {
    public init(url: URL, includeEdges: Bool = true) async throws {
        let loader = ModelLoader(url: url)
        let loadedModel = try await loader.load()

        struct ComponentProducts: Sendable {
            let mainGeometry: SCNGeometry
            let sharpEdgesGeometry: SCNGeometry
            let smoothEdgesGeometry: SCNGeometry
            let mesh: ThreeMF.Mesh
            let emittedCorners: [Int32]
            let stats: ModelData.Statistics
            let transform: SCNMatrix4
        }

        let indexedEdgeGeometries: [(sharp: SCNGeometry, smooth: SCNGeometry)]
        if includeEdges {
            indexedEdgeGeometries = await loadedModel.meshes.asyncMap { $0.mesh.edgeGeometries() }
        } else {
            indexedEdgeGeometries = []
        }

        let parts = await Array(loadedModel.items.enumerated()).asyncMap { itemIndex, loadedItem in
            let products = await loadedItem.components.asyncMap { loadedComponent in
                let property = PartialPropertyReference(groupID: loadedComponent.propertyGroupID, index: loadedComponent.propertyIndex)
                let loadedMesh = loadedModel.meshes[loadedComponent.meshIndex]
                let model = loadedModel.models[loadedMesh.modelIndex]

                let (geometry, emittedCorners) = model.geometry(for: loadedMesh.mesh, inheritedProperty: property)

                if includeEdges && loadedComponent.meshIndex < indexedEdgeGeometries.count {
                    let (sharp, smooth) = indexedEdgeGeometries[loadedComponent.meshIndex]
                    return ComponentProducts(
                        mainGeometry: geometry,
                        sharpEdgesGeometry: sharp,
                        smoothEdgesGeometry: smooth,
                        mesh: loadedMesh.mesh,
                        emittedCorners: emittedCorners,
                        stats: loadedMesh.mesh.statistics,
                        transform: loadedComponent.scnMatrix
                    )
                } else {
                    let emptyGeometry = SCNGeometry()
                    return ComponentProducts(
                        mainGeometry: geometry,
                        sharpEdgesGeometry: emptyGeometry,
                        smoothEdgesGeometry: emptyGeometry,
                        mesh: loadedMesh.mesh,
                        emittedCorners: emittedCorners,
                        stats: loadedMesh.mesh.statistics,
                        transform: loadedComponent.scnMatrix
                    )
                }
            }

            var nodes = Part.Nodes()
            nodes.container.name = "Item \(itemIndex)"

            if includeEdges && loadedItem.item.semantic == .solid {
                let sharpEdgesGroupNode = SCNNode()
                let smoothEdgesGroupNode = SCNNode()
                nodes.sharpEdges = sharpEdgesGroupNode
                nodes.smoothEdges = smoothEdgesGroupNode
                sharpEdgesGroupNode.name = "Sharp edges"
                smoothEdgesGroupNode.name = "Smooth edges"
                nodes.container.addChildNode(sharpEdgesGroupNode)
                nodes.container.addChildNode(smoothEdgesGroupNode)

                for product in products {
                    let sharpNodeContainer = SCNNode()
                    sharpNodeContainer.name = "Sharp edges transformer"
                    sharpNodeContainer.transform = product.transform
                    sharpEdgesGroupNode.addChildNode(sharpNodeContainer)

                    let sharpNode = SCNNode(geometry: product.sharpEdgesGeometry)
                    sharpNode.name = "Sharp edges geometry"
                    sharpNodeContainer.addChildNode(sharpNode)

                    let smoothNodeContainer = SCNNode()
                    smoothNodeContainer.name = "Smooth edges transformer"
                    smoothNodeContainer.transform = product.transform
                    smoothEdgesGroupNode.addChildNode(smoothNodeContainer)

                    let smoothNode = SCNNode(geometry: product.smoothEdgesGeometry)
                    smoothNode.name = "Smooth edges geometry"
                    smoothNodeContainer.addChildNode(smoothNode)
                }
            }

            var modelGeometryVariants: [ModelGeometryVariant] = []
            for product in products {
                let modelNode = SCNNode(geometry: product.mainGeometry)
                modelNode.name = "Main geometry"
                modelNode.transform = product.transform
                nodes.model.addChildNode(modelNode)
                modelGeometryVariants.append(ModelGeometryVariant(
                    node: modelNode,
                    flat: product.mainGeometry,
                    mesh: product.mesh,
                    emittedCorners: product.emittedCorners
                ))
            }

            return Part(
                nodes: nodes,
                name: loadedItem.rootObject.name ?? "Object \(itemIndex + 1)",
                id: loadedItem.item.partNumber,
                semantic: loadedItem.item.semantic,
                stats: Statistics(products.map(\.stats)),
                modelGeometryVariants: modelGeometryVariants
            )
        }

        let container = SCNNode()
        container.name = "Model root"
        if let multiplier = loadedModel.rootModel.unit?.millimetersPerUnit {
            container.transform = SCNMatrix4MakeScale(multiplier, multiplier, multiplier)
        }

        for part in parts {
            container.addChildNode(part.nodes.container)
        }

        self = Self(rootNode: container, parts: parts, metadata: loadedModel.rootModel.metadata)
    }
}

extension ModelLoader.LoadedModel.LoadedComponent {
    var scnMatrix: SCNMatrix4 {
        transforms.reduce(SCNMatrix4Identity) { transform, matrix in
            SCNMatrix4Mult(matrix.scnMatrix, transform)
        }
    }
}

extension ThreeMF.Model {
    public func object(for id: ResourceID) throws -> Object {
        guard let object = resources.resource(for: id) as? Object else {
            throw ThreeMFError.missingObject
        }
        return object
    }

    /// Builds the (flat) geometry for a mesh and, alongside it, records the emission order:
    /// `emittedCorners[i]` is the packed `triangleIndex * 3 + corner` that the i-th emitted
    /// vertex came from. This lets us later compute smooth per-vertex normals aligned to the
    /// vertex source without re-deriving the (material-grouped, transparency-filtered) order.
    public func geometry(for mesh: ThreeMF.Mesh, inheritedProperty: PartialPropertyReference) -> (geometry: SCNGeometry, emittedCorners: [Int32]) {
        var colors: [SCNVector4] = []
        var positions: [SCNVector3] = []
        var emittedCorners: [Int32] = []
        var elementPerMaterial: [PBRMaterial?: [Int32]] = [:]

        for (triangleIndex, triangle) in mesh.triangles.enumerated() {
            let material = material(for: triangle, inheritedProperty: inheritedProperty)
            guard material?.isFullyTransparent != true else {
                continue
            }

            let vertexIndices = (positions.count..<positions.count + 3).map(Int32.init)
            positions += [
                mesh.vertices[triangle.v1].scnVector3,
                mesh.vertices[triangle.v2].scnVector3,
                mesh.vertices[triangle.v3].scnVector3
            ]
            let cornerBase = Int32(triangleIndex * 3)
            emittedCorners += [cornerBase, cornerBase + 1, cornerBase + 2]

            if case .pbr (let pbrMaterial) = material {
                elementPerMaterial[pbrMaterial, default: []].append(contentsOf: vertexIndices)
            } else {
                elementPerMaterial[nil, default: []].append(contentsOf: vertexIndices)
            }

            let colorValues = material?.colorValues ?? [.white, .white, .white]
            colors += colorValues.map(\.scnVector4)
        }

        let vertexSource = SCNGeometrySource(vertices: positions)
        let colorSource = SCNGeometrySource.colors(colors)

        let orderedMaterials = Array(elementPerMaterial.keys)
        let elements = orderedMaterials.map {
            SCNGeometryElement(indices: elementPerMaterial[$0]!, primitiveType: .triangles)
        }

        let defaultMaterial = SCNMaterial()
        defaultMaterial.diffuse.contents = NSColor.white
        defaultMaterial.emission.intensity = 0
        defaultMaterial.transparencyMode = .singleLayer
        defaultMaterial.name = "Non-PBR material"

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: elements)
        geometry.materials = orderedMaterials.map { $0?.scnMaterial ?? defaultMaterial }
        geometry.name = UUID().uuidString
        return (geometry, emittedCorners)
    }
}

public enum ThreeMFError: Swift.Error {
    case missingObject
}

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

extension Mesh {
    public var statistics: ModelData.Statistics {
        .init(vertexCount: vertices.count, triangleCount: triangles.count)
    }

    public func edgeGeometries() -> (sharp: SCNGeometry, smooth: SCNGeometry) {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.black

        let positions: [SCNVector3] = vertices.map(\.scnVector3)
        let vertexSource = SCNGeometrySource(vertices: positions)
        let (sharpEdgesElement, smoothEdgesElement) = extractEdgeSegments()

        let sharpGeometry = SCNGeometry(sources: [vertexSource], elements: [sharpEdgesElement])
        sharpGeometry.materials = [material]

        let smoothGeometry = SCNGeometry(sources: [vertexSource], elements: [smoothEdgesElement])
        smoothGeometry.materials = [material]

        return (sharpGeometry, smoothGeometry)
    }

    private func extractEdgeSegments() -> (sharp: SCNGeometryElement, smooth: SCNGeometryElement) {
        struct Edge: Hashable {
            let v1: Int
            let v2: Int

            init(_ a: Int, _ b: Int) {
                if a < b {
                    v1 = a
                    v2 = b
                } else {
                    v1 = b
                    v2 = a
                }
            }
        }

        var edgeToTriangles: [Edge: [Int]] = [:]
        for (faceIndex, triangle) in triangles.enumerated() {
            let edges = [
                Edge(triangle.v1, triangle.v2),
                Edge(triangle.v2, triangle.v3),
                Edge(triangle.v3, triangle.v1)
            ]
            for edge in edges {
                edgeToTriangles[edge, default: []].append(faceIndex)
            }
        }

        func normal(of triangle: Triangle) -> SIMD3<Double> {
            let a = vertices[triangle.v1].simd
            let b = vertices[triangle.v2].simd
            let c = vertices[triangle.v3].simd
            let ab = b - a
            let ac = c - a
            return simd_normalize(simd_cross(ab, ac))
        }

        let triangleNormals = triangles.map { normal(of: $0) }

        let maxSmoothAngleDegrees = 30.0
        let angleThreshold = cos(maxSmoothAngleDegrees * .pi / 180.0)
        var featureEdges: [Edge] = []
        var smoothEdges: [Edge] = []

        for (edge, faces) in edgeToTriangles {
            if faces.count == 1 {
                smoothEdges.append(edge)
                
            } else if faces.count == 2 {
                let n1 = triangleNormals[faces[0]]
                let n2 = triangleNormals[faces[1]]
                let dot = simd_dot(n1, n2)
                if dot < angleThreshold {
                    featureEdges.append(edge)
                } else {
                    smoothEdges.append(edge)
                }
            }
        }

        return (
            sharp: SCNGeometryElement(indices: featureEdges.flatMap { [Int32($0.v1), Int32($0.v2)] }, primitiveType: .line),
            smooth: SCNGeometryElement(indices: smoothEdges.flatMap { [Int32($0.v1), Int32($0.v2)] }, primitiveType: .line)
        )
    }

    /// Crease-aware smooth normals, one per triangle corner, indexed by `triangleIndex * 3 + corner`.
    ///
    /// Face normals are averaged per shared vertex, but only across edges whose dihedral angle is
    /// within `creaseAngleDegrees` — the same threshold used to classify sharp/feature edges — so
    /// genuine sharp edges keep hard, faceted shading while curved surfaces shade smoothly. The
    /// shading creases therefore coincide with the drawn sharp edges. Degenerate (zero-area)
    /// triangles never contribute a NaN normal; corners always receive a valid, normalized normal.
    public func smoothCornerNormals(creaseAngleDegrees: Double = 30) -> [SCNVector3] {
        struct Edge: Hashable {
            let v1: Int
            let v2: Int
            init(_ a: Int, _ b: Int) {
                if a < b { v1 = a; v2 = b } else { v1 = b; v2 = a }
            }
        }

        let triangleCount = triangles.count
        let cornerCount = triangleCount * 3

        // Per-face normals, flagging degenerate triangles so they're excluded from averaging.
        var faceNormals = [SIMD3<Double>](repeating: .zero, count: triangleCount)
        var faceValid = [Bool](repeating: false, count: triangleCount)
        for (i, t) in triangles.enumerated() {
            let a = vertices[t.v1].simd
            let b = vertices[t.v2].simd
            let c = vertices[t.v3].simd
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            if length > 1e-12 {
                faceNormals[i] = cross / length
                faceValid[i] = true
            }
        }

        // Local corner index (0/1/2) of a given mesh-vertex within a triangle.
        func cornerIndex(of vertex: Int, in t: Triangle) -> Int {
            if t.v1 == vertex { return 0 }
            if t.v2 == vertex { return 1 }
            return 2
        }

        var edgeToTriangles: [Edge: [Int]] = [:]
        edgeToTriangles.reserveCapacity(cornerCount)
        for (faceIndex, t) in triangles.enumerated() {
            edgeToTriangles[Edge(t.v1, t.v2), default: []].append(faceIndex)
            edgeToTriangles[Edge(t.v2, t.v3), default: []].append(faceIndex)
            edgeToTriangles[Edge(t.v3, t.v1), default: []].append(faceIndex)
        }

        // Union-find over corners. Two corners are merged when they sit on the same mesh-vertex
        // and the edge connecting their triangles is smooth (within the crease threshold).
        var parent = Array(0..<cornerCount)
        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { parent[root] = parent[parent[root]]; root = parent[root] }
            return root
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        let cosThreshold = cos(creaseAngleDegrees * .pi / 180.0)
        for (edge, faces) in edgeToTriangles where faces.count == 2 {
            let f1 = faces[0], f2 = faces[1]
            guard faceValid[f1], faceValid[f2] else { continue }
            guard simd_dot(faceNormals[f1], faceNormals[f2]) >= cosThreshold else { continue }
            // Merge the corners at both endpoints of this shared, smooth edge.
            union(f1 * 3 + cornerIndex(of: edge.v1, in: triangles[f1]),
                  f2 * 3 + cornerIndex(of: edge.v1, in: triangles[f2]))
            union(f1 * 3 + cornerIndex(of: edge.v2, in: triangles[f1]),
                  f2 * 3 + cornerIndex(of: edge.v2, in: triangles[f2]))
        }

        // Interior angle at a corner, used to weight each face's contribution (Thürmer–Wüthrich),
        // which gives better normals on irregular tessellations than unweighted or area weighting.
        func cornerAngle(face f: Int, corner: Int) -> Double {
            let t = triangles[f]
            let p = [vertices[t.v1].simd, vertices[t.v2].simd, vertices[t.v3].simd]
            let origin = p[corner]
            let u = p[(corner + 1) % 3] - origin
            let v = p[(corner + 2) % 3] - origin
            let lu = simd_length(u), lv = simd_length(v)
            guard lu > 1e-12, lv > 1e-12 else { return 0 }
            return acos(min(1, max(-1, simd_dot(u, v) / (lu * lv))))
        }

        // Accumulate angle-weighted face normals into each smoothing group (keyed by its root).
        var groupNormals = [SIMD3<Double>](repeating: .zero, count: cornerCount)
        for f in 0..<triangleCount where faceValid[f] {
            for corner in 0..<3 {
                let weight = cornerAngle(face: f, corner: corner)
                groupNormals[find(f * 3 + corner)] += faceNormals[f] * weight
            }
        }

        var result = [SCNVector3](repeating: SCNVector3(0, 0, 1), count: cornerCount)
        for f in 0..<triangleCount {
            for corner in 0..<3 {
                let cornerID = f * 3 + corner
                var normal = groupNormals[find(cornerID)]
                let length = simd_length(normal)
                if length > 1e-12 {
                    normal /= length
                } else if faceValid[f] {
                    normal = faceNormals[f] // isolated/degenerate group → fall back to the face normal
                } else {
                    continue // keep the default; this corner belongs to a degenerate triangle
                }
                result[cornerID] = SCNVector3(normal.x, normal.y, normal.z)
            }
        }
        return result
    }
}

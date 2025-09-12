import Foundation
import ThreeMF
import SceneKit

struct ModelData {
    let rootNode: SCNNode
    let parts: [Part]
    let metadata: [ThreeMF.Metadata]

    init(rootNode: SCNNode, parts: [Part], metadata: [ThreeMF.Metadata]) {
        self.rootNode = rootNode
        self.parts = parts
        self.metadata = metadata
    }

    init() {
        self.init(rootNode: .init(), parts: [], metadata: [])
    }

    struct Part: Identifiable {
        typealias ID = String

        let nodes: Nodes
        let name: String?
        let id: ID
        let semantic: PartSemantic
        let statistics: Statistics

        init(nodes: Nodes, name: String?, id: ID?, semantic: PartSemantic, stats: Statistics) {
            self.nodes = nodes
            self.name = name
            self.id = id ?? UUID().uuidString
            self.semantic = semantic
            self.statistics = stats
        }

        var displayName: String {
            name ?? "Object"
        }

        struct Nodes {
            var container: SCNNode
            var model: SCNNode
            var sharpEdges: SCNNode?
            var smoothEdges: SCNNode?

            init() {
                container = SCNNode()
                model = SCNNode()
                container.addChildNode(model)
            }
        }
    }

    var statistics: Statistics {
        .init(parts.map(\.statistics))
    }
}

extension ModelData {
    struct Statistics {
        let vertexCount: Int
        let triangleCount: Int

        init(vertexCount: Int, triangleCount: Int) {
            self.vertexCount = vertexCount
            self.triangleCount = triangleCount
        }

        init(_ stats: [Statistics]) {
            self.init(
                vertexCount: stats.map(\.vertexCount).reduce(0, +),
                triangleCount: stats.map(\.triangleCount).reduce(0, +)
            )
        }
    }
}

extension ModelData {
    init(url: URL) async throws {
        let loader = ModelLoader(url: url)
        let loadedModel = try await loader.load()

        struct ComponentProducts {
            let mainGeometry: SCNGeometry
            let sharpEdgesGeometry: SCNGeometry
            let smoothEdgesGeometry: SCNGeometry
            let stats: ModelData.Statistics
            let transform: SCNMatrix4
        }

        let indexedEdgeGeometries = await loadedModel.meshes.asyncMap { $0.mesh.edgeGeometries() }

        let parts = await Array(loadedModel.items.enumerated()).asyncMap { itemIndex, loadedItem in
            let products = await loadedItem.components.asyncMap { loadedComponent in
                let property = PartialPropertyReference(groupID: loadedComponent.propertyGroupID, index: loadedComponent.propertyIndex)
                let (sharp, smooth) = indexedEdgeGeometries[loadedComponent.meshIndex]
                let loadedMesh = loadedModel.meshes[loadedComponent.meshIndex]
                let model = loadedModel.models[loadedMesh.modelIndex]

                let geometry = model.geometry(for: loadedMesh.mesh, inheritedProperty: property)
                return ComponentProducts(
                    mainGeometry: geometry,
                    sharpEdgesGeometry: sharp,
                    smoothEdgesGeometry: smooth,
                    stats: loadedMesh.mesh.statistics,
                    transform: loadedComponent.scnMatrix
                )
            }

            var nodes = Part.Nodes()
            nodes.container.name = "Item \(itemIndex)"

            if loadedItem.item.semantic == .solid {
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

            for product in products {
                let modelNode = SCNNode(geometry: product.mainGeometry)
                modelNode.name = "Main geometry"
                modelNode.transform = product.transform
                nodes.model.addChildNode(modelNode)
            }

            return Part(
                nodes: nodes,
                name: loadedItem.rootObject.name,
                id: loadedItem.item.partNumber,
                semantic: loadedItem.item.semantic,
                stats: Statistics(products.map(\.stats))
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
    func object(for id: ResourceID) throws -> Object {
        guard let object = resources.resource(for: id) as? Object else {
            throw ThreeMFError.missingObject
        }
        return object
    }

    func geometry(for mesh: ThreeMF.Mesh, inheritedProperty: PartialPropertyReference) -> SCNGeometry {
        var colors: [SCNVector4] = []
        var positions: [SCNVector3] = []
        var elementPerMaterial: [PBRMaterial?: [Int32]] = [:]

        for triangle in mesh.triangles {
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
        return geometry
    }
}

enum ThreeMFError: Swift.Error {
    case missingObject
}

extension Mesh {
    var statistics: ModelData.Statistics {
        .init(vertexCount: vertices.count, triangleCount: triangles.count)
    }

    func edgeGeometries() -> (sharp: SCNGeometry, smooth: SCNGeometry) {
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

        // Build adjacency map
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

        // Compute normals
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
            if faces.count == 1 { // Non-manifold?
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
            smooth: SCNGeometryElement(indices: smoothEdges.flatMap { [Int32($0.v1), Int32($0.v2)] }, primitiveType: .line),
        )
    }
}

import Foundation
import ThreeMF
import SceneKit

struct ModelData {
    let rootNode: SCNNode
    let parts: [Part]

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
            var model: SCNNode
            var sharpEdges: SCNNode?
            var smoothEdges: SCNNode?

            init() {
                model = SCNNode()
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

extension PackageReader {
    func modelData() throws -> ModelData {
        let model = try model()
        return try model.buildModelData()
    }
}

extension ThreeMF.Model {
    func object(for id: ResourceID) throws -> Object {
        guard let object = resources.resource(for: id) as? Object else {
            throw ThreeMFError.missingObject
        }
        return object
    }

    func buildModelData() throws -> ModelData {
        let container = SCNNode()
        container.name = "Model root"
        if let multiplier = unit?.millimetersPerUnit {
            container.transform = SCNMatrix4MakeScale(multiplier, multiplier, multiplier)
        }

        let parts = try buildItems.enumerated().map { index, item -> ModelData.Part in
            let part = try buildPart(item: item, index: index)
            part.nodes.smoothEdges?.isHidden = true
            container.addChildNode(part.nodes.model)
            return part
        }

        return ModelData(rootNode: container, parts: parts)
    }

    func buildPart(item: Item, index: Int) throws -> ModelData.Part {
        let object = try object(for: item.objectID)
        let (nodes, stats) = try self.node(for: object, with: item.semantic)

        let quotedName = if let name = object.name { " \"\(name)\"" } else { "" }
        nodes.model.name = "Object id \(object.id)\(quotedName) for item #\(index)"
        nodes.model.transform = item.scnTransform

        return ModelData.Part(nodes: nodes, name: object.name, id: item.partNumber, semantic: item.semantic, stats: stats)
    }

    func node(for object: ThreeMF.Object, with semantic: PartSemantic) throws -> (ModelData.Part.Nodes, ModelData.Statistics) {
        var nodes = ModelData.Part.Nodes()
        let quotedName = if let name = object.name { " \"\(name)\"" } else { "" }
        nodes.model.name = "Object id \(object.id)" + quotedName
        let stats: ModelData.Statistics

        switch object.content {
        case .mesh (let mesh):
            nodes.model.geometry = geometry(for: mesh, in: object)
            stats = mesh.statistics

            if semantic == .solid {
                let (sharpEdgesGeometry, smoothEdgesGeometry) = mesh.edgeGeometries()

                let sharpEdges = SCNNode(geometry: sharpEdgesGeometry)
                nodes.model.addChildNode(sharpEdges)
                sharpEdges.name = "edges"
                nodes.sharpEdges = sharpEdges

                let smoothEdges = SCNNode(geometry: smoothEdgesGeometry)
                nodes.model.addChildNode(smoothEdges)
                smoothEdges.name = "edges"
                nodes.smoothEdges = smoothEdges
            }

        case .components (let components):
            var componentStats: [ModelData.Statistics] = []
            nodes.sharpEdges = SCNNode()
            nodes.smoothEdges = SCNNode()
            for component in components {
                let subobject = try self.object(for: component.objectID)
                let (subnodes, stats) = try self.node(for: subobject, with: semantic)

                subnodes.model.transform = component.scnTransform
                nodes.model.addChildNode(subnodes.model)
                if let sharpEdges = subnodes.sharpEdges {
                    nodes.sharpEdges?.addChildNode(sharpEdges)
                }
                if let smoothEdges = subnodes.smoothEdges {
                    nodes.smoothEdges?.addChildNode(smoothEdges)
                }
                componentStats.append(stats)
            }
            stats = .init(componentStats)
        }

        return (nodes, stats)
    }

    func geometry(for mesh: ThreeMF.Mesh, in object: Object) -> SCNGeometry {
        var colors: [SCNVector4] = []
        var positions: [SCNVector3] = []
        var elementPerMaterial: [PBRMaterial?: [Int32]] = [:]

        for triangle in mesh.triangles {
            let material = material(for: triangle, in: object)
            guard material?.isFullyTransparent == false else {
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

    func extractEdgeSegments() -> (sharp: SCNGeometryElement, smooth: SCNGeometryElement) {
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

        let maxSmoothAngleDegrees = 30.0 //3.0
        let angleThreshold = cos(maxSmoothAngleDegrees * .pi / 180.0)
        var featureEdges: [Edge] = []
        var smoothEdges: [Edge] = []

        for (edge, faces) in edgeToTriangles {
            if faces.count == 1 {
                // Non-manifold?
                featureEdges.append(edge)
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

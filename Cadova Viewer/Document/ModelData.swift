import Foundation
import ThreeMF
import SceneKit

struct ModelData {
    let rootNode: SCNNode
    let parts: [Part]

    struct Part: Identifiable {
        typealias ID = String

        let node: SCNNode
        let name: String?
        let id: ID
        let semantic: PartSemantic
        let statistics: Statistics

        init(node: SCNNode, name: String?, id: ID?, semantic: PartSemantic, stats: Statistics) {
            self.node = node
            self.name = name
            self.id = id ?? UUID().uuidString
            self.semantic = semantic
            self.statistics = stats
        }

        var displayName: String {
            name ?? "Object"
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
            container.addChildNode(part.node)
            return part
        }

        return ModelData(rootNode: container, parts: parts)
    }

    func buildPart(item: Item, index: Int) throws -> ModelData.Part {
        let object = try object(for: item.objectID)
        let (node, stats) = try self.node(for: object, with: item.semantic)

        let quotedName = if let name = object.name { " \"\(name)\"" } else { "" }
        node.name = "Object id \(object.id)\(quotedName) for item #\(index)"
        node.transform = item.scnTransform

        return ModelData.Part(node: node, name: object.name, id: item.partNumber, semantic: item.semantic, stats: stats)
    }

    func node(for object: ThreeMF.Object, with semantic: PartSemantic) throws -> (SCNNode, ModelData.Statistics) {
        let node = SCNNode()
        let quotedName = if let name = object.name { " \"\(name)\"" } else { "" }
        node.name = "Object id \(object.id)" + quotedName
        let stats: ModelData.Statistics

        switch object.content {
        case .mesh (let mesh):
            node.geometry = geometry(for: mesh, in: object)
            stats = mesh.statistics

            if semantic == .solid {
                let edgeNode = SCNNode(geometry: mesh.visibleEdgeGeometry())
                node.addChildNode(edgeNode)
                edgeNode.name = "edges"
            }

        case .components (let components):
            var componentStats: [ModelData.Statistics] = []
            for component in components {
                let subobject = try self.object(for: component.objectID)
                let (subnode, stats) = try self.node(for: subobject, with: semantic)
                subnode.transform = component.scnTransform
                node.addChildNode(subnode)
                componentStats.append(stats)
            }
            stats = .init(componentStats)
        }

        return (node, stats)
    }

    func geometry(for mesh: ThreeMF.Mesh, in object: Object) -> SCNGeometry {
        var colors: [SCNVector4] = []
        var positions: [SCNVector3] = []
        let defaultColor = Color.white

        var elementPerMaterial: [ComplexMaterial?: [Int32]] = [:]

        for triangle in mesh.triangles {
            let material = material(for: triangle, in: object)
            let colorValues = material?.colorValues ?? [defaultColor, defaultColor, defaultColor]

            if material?.isFullyTransparent == true {
                continue
            }

            let vertexIndices = (positions.count..<positions.count + 3).map(Int32.init)

            positions += [
                mesh.vertices[triangle.v1].scnVector3,
                mesh.vertices[triangle.v2].scnVector3,
                mesh.vertices[triangle.v3].scnVector3
            ]

            if case .complex (let complexMaterial) = material {
                elementPerMaterial[complexMaterial, default: []].append(contentsOf: vertexIndices)
            } else {
                elementPerMaterial[nil, default: []].append(contentsOf: vertexIndices)
            }

            colors += colorValues.map(\.scnVector4)
        }

        let vertexSource = SCNGeometrySource(vertices: positions)
        let colorSource = SCNGeometrySource.colors(colors)

        let orderedMaterials = Array(elementPerMaterial.keys)
        let elements = orderedMaterials.map {
            SCNGeometryElement(indices: elementPerMaterial[$0]!, primitiveType: .triangles)
        }

        let defaultMaterial = SCNMaterial()
        defaultMaterial.diffuse.contents = defaultColor.nsColor
        defaultMaterial.emission.intensity = 0
        defaultMaterial.transparencyMode = .singleLayer
        defaultMaterial.name = "Non-PBR material"

        let materials = orderedMaterials.map {
            $0?.scnMaterial ?? defaultMaterial
        }

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: elements)
        geometry.materials = materials
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

    func visibleEdgeGeometry() -> SCNGeometry {
        let positions: [SCNVector3] = vertices.map(\.scnVector3)
        let vertexSource = SCNGeometrySource(vertices: positions)
        let element = visibleEdgeSegments()
        let geometry = SCNGeometry(sources: [vertexSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.black
        geometry.materials = [material]
        return geometry
    }

    func visibleEdgeSegments() -> SCNGeometryElement {
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
                }
            }
        }

        let indices = featureEdges.flatMap { [Int32($0.v1), Int32($0.v2)] }
        return SCNGeometryElement(indices: indices, primitiveType: .line)
    }
}

import Foundation
import ThreeMF
import SceneKit
import ModelIO
import Nodal

struct ModelData {
    let rootNode: SCNNode
    let parts: [Part]

    struct Part: Identifiable {
        typealias ID = String

        let node: SCNNode
        let name: String?
        let id: ID
        let kind: Kind

        init(node: SCNNode, name: String?, id: ID?, kind: Kind) {
            self.node = node
            self.name = name
            self.id = id ?? UUID().uuidString
            self.kind = kind
        }

        var displayName: String {
            name ?? "Object"
        }

        enum Kind {
            case model
            case secondary
        }
    }
}

extension PackageReader {
    func sceneKitNode() throws -> ModelData {
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

        let parts = try buildItems.enumerated().compactMap { index, item -> ModelData.Part? in
            guard let node = try buildNode(item: item, index: index) else {
                return nil
            }
            container.addChildNode(node)

            let object = try object(for: item.objectID)
            let kind: ModelData.Part.Kind = (object.type ?? .model) == .model ? .model : .secondary
            return ModelData.Part(node: node, name: object.name, id: item.partNumber, kind: kind)
        }

        return ModelData(rootNode: container, parts: parts)
    }

    func buildNode(item: Item, index: Int) throws -> SCNNode? {
        let semantic: PartSemantic
        if let attribute = item.customAttributes[.semantic], let parsed = PartSemantic(xmlAttributeValue: attribute) {
            semantic = parsed
        } else {
            semantic = .solid
        }

        let object = try object(for: item.objectID)
        let node = try self.node(for: object, with: semantic)

        let quotedName = if let name = object.name { " \"\(name)\"" } else { "" }
        node.name = "Object id \(object.id)\(quotedName) for item #\(index)"

        if let transform = item.transform {
            node.transform = transform.scnMatrix
        }
        return node
    }

    func node(for object: ThreeMF.Object, with semantic: PartSemantic) throws -> SCNNode {
        let node = SCNNode()
        let quotedName = if let name = object.name { " \"\(name)\"" } else { "" }
        node.name = "Object id \(object.id)" + quotedName

        switch object.content {
        case .mesh (let mesh):
            node.geometry = geometry(for: mesh, in: object)

            if semantic == .solid {
                let edgeNode = SCNNode(geometry: mesh.visibleEdgeGeometry())
                node.addChildNode(edgeNode)
                edgeNode.name = "edges"
            }

        case .components (let components):
            for component in components {
                let subobject = try self.object(for: component.objectID)
                let subnode = try self.node(for: subobject, with: semantic)
                if let transform = component.transform {
                    subnode.transform = transform.scnMatrix
                }
                node.addChildNode(subnode)
            }
        }

        return node
    }

    func colorGroup(for resourceID: ResourceID) -> ColorGroup? {
        guard let match = resources.resource(for: resourceID) as? ColorGroup else {
            return nil
        }
        return match
    }

    func color(for propertyReference: PropertyReference) -> (color: Color, displayProperties: PropertyReference?)? {
        let group = resources.resource(for: propertyReference.groupID)

        if let colorGroup = group as? ColorGroup {
            let display = colorGroup.displayPropertiesID.map { PropertyReference(groupID: $0, index: propertyReference.index) }
            guard let color = colorGroup.colors[safe: propertyReference.index] else { return nil }
            return (color, display)

        } else if let baseMaterialGroup = group as? BaseMaterialGroup {
            let display = baseMaterialGroup.displayPropertiesID.map { PropertyReference(groupID: $0, index: propertyReference.index) }
            guard let color = baseMaterialGroup.properties[safe: propertyReference.index]?.displayColor else { return nil }
            return (color, display)

        } else {
            return nil
        }
    }

    func complexMaterial(for property: PropertyReference, baseColor: Color) -> ComplexMaterial? {
        guard let group = resources.resource(for: property.groupID) else {
            return nil
        }
        if let displayProperties = group as? MetallicDisplayProperties, let item = displayProperties.metallics[safe: property.index] {
            return .metallic(diffuse: baseColor, metallicness: item.metallicness, roughness: item.roughness, name: item.name)

        } else if let displayProperties = group as? SpecularDisplayProperties, let item = displayProperties.speculars[safe: property.index] {
            let (specularColor, glossiness) = item.effectiveValues
            return .specular(diffuse: baseColor, specularColor: specularColor, glossiness: glossiness, name: item.name)

        } else {
            return nil
        }
    }

    func material(for triangle: Mesh.Triangle, in object: Object) -> Material? {
        guard let refs = triangle.resolvedProperties(in: object) else {
            return nil
        }

        if refs.count == 3 {
            guard let colors = refs.map({ color(for: $0)?.color }) as? [Color] else {
                return nil
            }
            return .colors(colors[0], colors[1], colors[2])

        } else if refs.count == 1 {
            guard let (color, displayPropsID) = color(for: refs[0]) else { return nil }
            if let displayPropsID, let complex = complexMaterial(for: displayPropsID, baseColor: color) {
                return .complex(complex)
            } else {
                return .colors(color, color, color)
            }
        } else {
            return nil
        }
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
        defaultMaterial.transparencyMode = .dualLayer
        defaultMaterial.name = "Default material"

        let materials = orderedMaterials.map {
            $0?.scnMaterial ?? defaultMaterial
        }

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: elements)
        geometry.materials = materials
        geometry.name = UUID().uuidString
        return geometry
    }
}

enum Material {
    case colors (Color, Color, Color)
    case complex (ComplexMaterial)

    var isFullyTransparent: Bool {
        if case let .colors(color, color2, color3) = self {
            color.isFullyTransparent && color2.isFullyTransparent && color3.isFullyTransparent
        } else {
            false
        }
    }

    var colorValues: [Color]? {
        if case let .colors(color, color2, color3) = self {
            [color, color2, color3]
        } else {
            nil
        }
    }
}

enum ComplexMaterial: Hashable {
    case metallic (diffuse: Color, metallicness: Double, roughness: Double, name: String?)
    case specular (diffuse: Color, specularColor: Color, glossiness: Double, name: String?)
}

extension ComplexMaterial {
    var scnMaterial: SCNMaterial {
        let material = SCNMaterial()
        switch self {
        case .metallic(let diffuse, let metallicness, let roughness, let name):
            material.lightingModel = .physicallyBased
            material.diffuse.contents = diffuse.nsColor
            material.metalness.contents = NSNumber(value: metallicness)
            material.roughness.contents = NSNumber(value: roughness)
            material.name = name
            if !diffuse.isOpaque {
                material.transparencyMode = .dualLayer
            }

        case .specular(let diffuse, let specularColor, let glossiness, let name):
            material.diffuse.contents = diffuse.nsColor
            material.specular.contents = specularColor.nsColor
            material.shininess = glossiness
            material.lightingModel = .blinn
            material.name = name
            if !diffuse.isOpaque {
                material.transparencyMode = .dualLayer
            }
        }

        material.emission.intensity = 0
        return material
    }
}

enum ThreeMFError: Swift.Error {
    case missingObject
}

extension ThreeMF.Matrix3D {
    var scnMatrix: SCNMatrix4 {
        let v = values
        return SCNMatrix4(
            m11: v[0][0], m12: v[0][1], m13: v[0][2], m14: 0,
            m21: v[1][0], m22: v[1][1], m23: v[1][2], m24: 0,
            m31: v[2][0], m32: v[2][1], m33: v[2][2], m34: 0,
            m41: v[3][0], m42: v[3][1], m43: v[3][2], m44: 1
        )
    }
}

extension ThreeMF.Color {
    var scnVector4: SCNVector4 {
        .init(Double(red) / 255.0, Double(green) / 255.0, Double(blue) / 255.0, Double(alpha) / 255.0)
    }

    var nsColor: NSColor {
        .init(red: Double(red) / 255.0, green: Double(green) / 255.0, blue: Double(blue) / 255.0, alpha: Double(alpha) / 255.0)
    }

    static let white = Self.init(red: 0xFF, green: 0xFF, blue: 0xFF)

    var isFullyTransparent: Bool {
        alpha == 0
    }
}

extension ThreeMF.Mesh.Vertex {
    var scnVector3: SCNVector3 {
        .init(x, y, z)
    }

    var simd: SIMD3<Double> {
        .init(x, y, z)
    }
}


extension Mesh {
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

        print("\(featureEdges.count) feature edges")
        let indices = featureEdges.flatMap { [Int32($0.v1), Int32($0.v2)] }
        return SCNGeometryElement(indices: indices, primitiveType: .line)
    }
}

enum PartSemantic: String, Hashable, Sendable, Codable {
    /// A regular printable part, typically rendered as opaque and included in the physical output.
    case solid

    /// A background or reference part used for spatial context. These parts are included in the model for visualization,
    /// but are not intended to be printed or interact with the printable geometry.
    case context

    /// A visual-only part used for display, guidance, or context. These are not intended for printing.
    case visual
}

fileprivate extension ExpandedName {
    static let printable = ExpandedName(namespaceName: nil, localName: "printable")
    static let semantic = CadovaNamespace.semantic
}

fileprivate struct CadovaNamespace {
    static let uri = "https://cadova.org/3mf"
    static let semantic = ExpandedName(namespaceName: uri, localName: "semantic")
}

fileprivate extension PartSemantic {
    init?(xmlAttributeValue value: String) {
        self.init(rawValue: value)
    }

    var xmlAttributeValue: String { rawValue }
}

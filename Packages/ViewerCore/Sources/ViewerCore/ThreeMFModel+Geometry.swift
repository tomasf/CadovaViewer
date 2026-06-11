import Foundation
import ThreeMF
import SceneKit
import AppKit

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

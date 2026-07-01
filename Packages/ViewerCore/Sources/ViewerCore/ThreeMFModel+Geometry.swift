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
    public func geometry(for mesh: ThreeMF.Mesh, inheritedProperty: PartialPropertyReference) -> (geometry: SCNGeometry, emittedCorners: [Int32], dominantColor: SIMD4<Float>?) {
        var colors: [SCNVector4] = []
        var positions: [SCNVector3] = []
        var emittedCorners: [Int32] = []
        var elementPerMaterial: [PBRMaterial?: [Int32]] = [:]

        // Track, per material group, how many triangles use it and the sum of their corner colors,
        // so we can pick a representative ("dominant") colour for the cross-section cap fill: the
        // colour of whichever material covers the most of the part. PBR groups use their diffuse;
        // the vertex-colour group averages its accumulated corner colours.
        var triangleCountPerMaterial: [PBRMaterial?: Int] = [:]
        var colorSumPerMaterial: [PBRMaterial?: SIMD4<Double>] = [:]

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

            let materialKey: PBRMaterial?
            if case .pbr (let pbrMaterial) = material {
                materialKey = pbrMaterial
            } else {
                materialKey = nil
            }
            elementPerMaterial[materialKey, default: []].append(contentsOf: vertexIndices)
            triangleCountPerMaterial[materialKey, default: 0] += 1

            let colorValues = material?.colorValues ?? [.white, .white, .white]
            let cornerColors = colorValues.map(\.scnVector4)
            colors += cornerColors
            colorSumPerMaterial[materialKey, default: .zero] += cornerColors.reduce(.zero) { $0 + SIMD4($1.x, $1.y, $1.z, $1.w) }
        }

        let dominantColor = dominantColor(
            triangleCountPerMaterial: triangleCountPerMaterial,
            colorSumPerMaterial: colorSumPerMaterial
        )

        let vertexSource = SCNGeometrySource(vertices: positions)
        let colorSource = SCNGeometrySource.colors(colors)

        let orderedMaterials = Array(elementPerMaterial.keys)
        let elements = orderedMaterials.map {
            SCNGeometryElement(indices: elementPerMaterial[$0]!, primitiveType: .triangles)
        }

        let defaultMaterial = SCNMaterial()
        // Vertex colors can go fully black, at which point plain diffuse shading contributes
        // nothing regardless of light direction. Physically-based shading keeps a Fresnel
        // specular response independent of albedo, so black parts still pick up highlights
        // and IBL reflections instead of reading as flat, depth-less silhouettes.
        defaultMaterial.lightingModel = .physicallyBased
        defaultMaterial.diffuse.contents = NSColor.white
        defaultMaterial.metalness.contents = 0 as NSNumber
        defaultMaterial.roughness.contents = 0.5 as NSNumber
        defaultMaterial.emission.intensity = 0
        defaultMaterial.transparencyMode = .singleLayer
        defaultMaterial.name = "Vertex-color material"

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: elements)
        geometry.materials = orderedMaterials.map { $0?.scnMaterial ?? defaultMaterial }
        geometry.name = UUID().uuidString
        return (geometry, emittedCorners, dominantColor)
    }

    /// The colour of whichever material group covers the most triangles, as linear RGBA. PBR groups
    /// use their diffuse colour; the vertex-colour group (`nil` key) averages its corner colours.
    private func dominantColor(
        triangleCountPerMaterial: [PBRMaterial?: Int],
        colorSumPerMaterial: [PBRMaterial?: SIMD4<Double>]
    ) -> SIMD4<Float>? {
        guard let (key, triangleCount) = triangleCountPerMaterial.max(by: { $0.value < $1.value }), triangleCount > 0 else {
            return nil
        }
        if let pbrMaterial = key {
            let c = pbrMaterial.diffuse.scnVector4
            return SIMD4(Float(c.x), Float(c.y), Float(c.z), Float(c.w))
        } else {
            let sum = colorSumPerMaterial[key] ?? .zero
            let average = sum / Double(triangleCount * 3)
            return SIMD4(Float(average.x), Float(average.y), Float(average.z), Float(average.w))
        }
    }
}

public enum ThreeMFError: Swift.Error {
    case missingObject
}

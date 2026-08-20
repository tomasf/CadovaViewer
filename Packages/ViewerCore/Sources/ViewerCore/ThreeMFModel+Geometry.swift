import Foundation
import ThreeMF
import SceneKit
import AppKit

/// The result of building a mesh's (flat) `SCNGeometry`.
public struct MeshGeometryResult: Sendable {
    public let geometry: SCNGeometry
    /// `emittedCorners[i]` is the packed `triangleIndex * 3 + corner` that the i-th emitted vertex
    /// came from. Lets smooth per-vertex normals be computed later, aligned to the vertex source,
    /// without re-deriving the (material-grouped, transparency-filtered) emission order.
    public let emittedCorners: [Int32]
    /// A representative colour for the mesh (the colour of its largest material group), as linear
    /// RGBA. `nil` when the mesh has no drawable geometry.
    public let dominantColor: SIMD4<Float>?
    /// Whether any triangle resolved an explicit material property at all — a PBR `<basematerials>`
    /// group *or* a colour group — as opposed to falling back to the plain, uncoloured default.
    /// Used to tell whether the model has any real "materials" to toggle at all.
    public let hasMaterial: Bool
}

extension ThreeMF.Model {
    public func object(for id: ResourceID) throws -> Object {
        guard let object = resources.resource(for: id) as? Object else {
            throw ThreeMFError.missingObject
        }
        return object
    }

    /// Builds the (flat) geometry for a mesh, alongside its emission order, dominant colour, and
    /// whether it has any real material (see `MeshGeometryResult`).
    ///
    /// This used to also split `mesh.triangles` into chunks processed concurrently via
    /// `DispatchQueue.concurrentPerform`, on top of the per-mesh `asyncMap` parallelism already in
    /// `ModelData.init(url:)`/`init(liveLink:)` — the idea being that a model dominated by a few
    /// huge meshes among many small ones leaves most cores idle waiting on the big ones. That part
    /// was real in a Debug build, where the per-triangle work itself was slow enough that dispatch
    /// overhead was negligible by comparison. Benchmarked in Release (what actually ships) against
    /// a real 1.93M-triangle, 49-part model, it was a net loss — `-O` optimizes the per-triangle
    /// work down far enough that `concurrentPerform`'s per-chunk dispatch and merge cost more than
    /// they saved (0.644s chunked vs. 0.569s serial for this whole function). The one-time
    /// allocation cleanup below (hoisting `defaultColorValues`, individual `.append`s instead of
    /// literal-then-`append(contentsOf:)`) is the part of that investigation that held up in
    /// Release and is kept; the chunking is not.
    public func geometry(for mesh: ThreeMF.Mesh, inheritedProperty: PartialPropertyReference) -> MeshGeometryResult {
        var colors: [SCNVector4] = []
        var positions: [SCNVector3] = []
        var emittedCorners: [Int32] = []
        var elementPerMaterial: [PBRMaterial?: [Int32]] = [:]
        var triangleCountPerMaterial: [PBRMaterial?: Int] = [:]
        var colorSumPerMaterial: [PBRMaterial?: SIMD4<Double>] = [:]
        var hasMaterial = false

        positions.reserveCapacity(mesh.triangles.count * 3)
        colors.reserveCapacity(mesh.triangles.count * 3)
        emittedCorners.reserveCapacity(mesh.triangles.count * 3)

        // Hoisted out of the loop: `material?.colorValues ?? [.white, .white, .white]` previously
        // allocated a fresh 3-element array on every triangle that isn't `.vertexColors` (i.e.
        // every PBR-materialed triangle, not just untextured ones) — a real cost at a few hundred
        // thousand triangles per mesh.
        let defaultColorValues: [ThreeMF.Color] = [.white, .white, .white]

        for (triangleIndex, triangle) in mesh.triangles.enumerated() {
            let material = material(for: triangle, inheritedProperty: inheritedProperty)
            guard material?.isFullyTransparent != true else {
                continue
            }
            if material != nil {
                hasMaterial = true
            }

            let base = Int32(positions.count)
            positions.append(mesh.vertices[triangle.v1].scnVector3)
            positions.append(mesh.vertices[triangle.v2].scnVector3)
            positions.append(mesh.vertices[triangle.v3].scnVector3)
            let cornerBase = Int32(triangleIndex * 3)
            emittedCorners.append(cornerBase)
            emittedCorners.append(cornerBase + 1)
            emittedCorners.append(cornerBase + 2)

            let materialKey: PBRMaterial?
            if case .pbr (let pbrMaterial) = material {
                materialKey = pbrMaterial
            } else {
                materialKey = nil
            }
            // A single dictionary access (one hash + lookup) beats three, even at the cost of one
            // small array literal to hand to `append(contentsOf:)`.
            elementPerMaterial[materialKey, default: []].append(contentsOf: [base, base + 1, base + 2])
            triangleCountPerMaterial[materialKey, default: 0] += 1

            let colorValues = material?.colorValues ?? defaultColorValues
            var cornerColorSum = SIMD4<Double>.zero
            for value in colorValues {
                let c = value.scnVector4
                colors.append(c)
                cornerColorSum += SIMD4(c.x, c.y, c.z, c.w)
            }
            colorSumPerMaterial[materialKey, default: .zero] += cornerColorSum
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
        defaultMaterial.roughness.contents = 0.9 as NSNumber
        defaultMaterial.emission.intensity = 0
        defaultMaterial.transparencyMode = .singleLayer
        defaultMaterial.name = "Vertex-color material"

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: elements)
        geometry.materials = orderedMaterials.map { $0?.scnMaterial ?? defaultMaterial }
        geometry.name = UUID().uuidString
        return MeshGeometryResult(geometry: geometry, emittedCorners: emittedCorners, dominantColor: dominantColor, hasMaterial: hasMaterial)
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

    /// Each triangle's own colour (a PBR triangle's diffuse, or the average of a vertex-colour
    /// triangle's corners), as linear RGBA — using only the triangle's *own* explicit colour
    /// property, never a component's inherited default. `nil` where the triangle has no explicit
    /// property of its own, since it would then rely on a specific component's inherited colour,
    /// which isn't knowable independent of which part instances the mesh. Used to colour individual
    /// edges by their neighbouring faces rather than by a single colour for the whole part.
    public func explicitTriangleColors(for mesh: ThreeMF.Mesh) -> [SIMD4<Float>?] {
        let noInheritance = PartialPropertyReference(groupID: nil, index: nil)
        return mesh.triangles.map { triangle in
            switch material(for: triangle, inheritedProperty: noInheritance) {
            case .pbr(let pbrMaterial):
                let c = pbrMaterial.diffuse.scnVector4
                return SIMD4(Float(c.x), Float(c.y), Float(c.z), Float(c.w))
            case .vertexColors(let c1, let c2, let c3):
                let v1 = c1.scnVector4, v2 = c2.scnVector4, v3 = c3.scnVector4
                return SIMD4(
                    Float((v1.x + v2.x + v3.x) / 3),
                    Float((v1.y + v2.y + v3.y) / 3),
                    Float((v1.z + v2.z + v3.z) / 3),
                    Float((v1.w + v2.w + v3.w) / 3)
                )
            case .none:
                return nil
            }
        }
    }
}

public enum ThreeMFError: Swift.Error {
    case missingObject
}

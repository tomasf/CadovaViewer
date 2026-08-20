import Foundation
import Dispatch
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
    /// Above `chunkedGeometryTriangleThreshold`, this splits `mesh.triangles` into contiguous
    /// chunks processed concurrently via `DispatchQueue.concurrentPerform`, then merges the chunk
    /// results back in original order — see `ChunkResult` and the merge loop below. This matters
    /// because per-mesh parallelism (in `ModelData.init(url:)`/`init(liveLink:)`) is only as good
    /// as the load balance across meshes: a model dominated by a few huge meshes among many small
    /// ones leaves most cores idle waiting on the big ones, since each mesh previously ran on a
    /// single core regardless of size.
    public func geometry(for mesh: ThreeMF.Mesh, inheritedProperty: PartialPropertyReference) -> MeshGeometryResult {
        let chunks = mesh.triangles.count.chunkedRanges(threshold: Self.chunkedGeometryTriangleThreshold)
        let storage = ChunkResultStorage(count: chunks.count)
        DispatchQueue.concurrentPerform(iterations: chunks.count) { chunkIndex in
            storage[chunkIndex] = self.chunkResult(
                for: mesh,
                triangleRange: chunks[chunkIndex],
                inheritedProperty: inheritedProperty
            )
        }

        var colors: [SCNVector4] = []
        var positions: [SCNVector3] = []
        var emittedCorners: [Int32] = []
        var elementPerMaterial: [PBRMaterial?: [Int32]] = [:]
        var triangleCountPerMaterial: [PBRMaterial?: Int] = [:]
        var colorSumPerMaterial: [PBRMaterial?: SIMD4<Double>] = [:]
        var hasMaterial = false

        // Chunks are merged in order, so the concatenated positions/colors/emittedCorners exactly
        // match what a single serial pass would have produced — only the per-material index lists
        // need adjusting, by the running position count before each chunk.
        for chunk in storage.results {
            let offset = Int32(positions.count)
            positions += chunk.positions
            colors += chunk.colors
            emittedCorners += chunk.emittedCorners
            for (key, indices) in chunk.elementPerMaterial {
                elementPerMaterial[key, default: []].append(contentsOf: indices.map { $0 + offset })
            }
            for (key, count) in chunk.triangleCountPerMaterial {
                triangleCountPerMaterial[key, default: 0] += count
            }
            for (key, sum) in chunk.colorSumPerMaterial {
                colorSumPerMaterial[key, default: .zero] += sum
            }
            hasMaterial = hasMaterial || chunk.hasMaterial
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

    /// Below this many triangles, chunking overhead (task setup, dictionary merging) isn't worth
    /// it — `geometry(for:inheritedProperty:)` just processes the whole mesh as one chunk.
    private static let chunkedGeometryTriangleThreshold = 20_000

    /// One chunk's worth of `geometry(for:inheritedProperty:)`'s per-triangle processing — same
    /// logic as a serial pass over `triangleRange`, just scoped to that range so it can run
    /// alongside other chunks. `cornerBase` uses the triangle's real (global) index, so
    /// `emittedCorners` needs no adjustment when chunks are concatenated; only `elementPerMaterial`'s
    /// indices (local to this chunk's `positions`) need offsetting, done by the caller.
    private func chunkResult(
        for mesh: ThreeMF.Mesh,
        triangleRange: Range<Int>,
        inheritedProperty: PartialPropertyReference
    ) -> ChunkResult {
        var result = ChunkResult()
        result.positions.reserveCapacity(triangleRange.count * 3)
        result.colors.reserveCapacity(triangleRange.count * 3)
        result.emittedCorners.reserveCapacity(triangleRange.count * 3)

        for triangleIndex in triangleRange {
            let triangle = mesh.triangles[triangleIndex]
            let material = material(for: triangle, inheritedProperty: inheritedProperty)
            guard material?.isFullyTransparent != true else {
                continue
            }
            if material != nil {
                result.hasMaterial = true
            }

            let vertexIndices = (result.positions.count..<result.positions.count + 3).map(Int32.init)
            result.positions += [
                mesh.vertices[triangle.v1].scnVector3,
                mesh.vertices[triangle.v2].scnVector3,
                mesh.vertices[triangle.v3].scnVector3
            ]
            let cornerBase = Int32(triangleIndex * 3)
            result.emittedCorners += [cornerBase, cornerBase + 1, cornerBase + 2]

            let materialKey: PBRMaterial?
            if case .pbr (let pbrMaterial) = material {
                materialKey = pbrMaterial
            } else {
                materialKey = nil
            }
            result.elementPerMaterial[materialKey, default: []].append(contentsOf: vertexIndices)
            result.triangleCountPerMaterial[materialKey, default: 0] += 1

            let colorValues = material?.colorValues ?? [.white, .white, .white]
            let cornerColors = colorValues.map(\.scnVector4)
            result.colors += cornerColors
            result.colorSumPerMaterial[materialKey, default: .zero] += cornerColors.reduce(.zero) { $0 + SIMD4($1.x, $1.y, $1.z, $1.w) }
        }
        return result
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

/// One chunk's partial output from `ThreeMF.Model.geometry(for:inheritedProperty:)`, merged with
/// its siblings (in chunk order) into the final `MeshGeometryResult`.
private struct ChunkResult {
    var positions: [SCNVector3] = []
    var colors: [SCNVector4] = []
    var emittedCorners: [Int32] = []
    var elementPerMaterial: [PBRMaterial?: [Int32]] = [:]
    var triangleCountPerMaterial: [PBRMaterial?: Int] = [:]
    var colorSumPerMaterial: [PBRMaterial?: SIMD4<Double>] = [:]
    var hasMaterial = false
}

private typealias ChunkResultStorage = ChunkStorage<ChunkResult>

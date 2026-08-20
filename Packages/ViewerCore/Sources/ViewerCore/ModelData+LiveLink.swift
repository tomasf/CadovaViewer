import Foundation
import ThreeMF
import SceneKit
import CadovaLiveLinkCore
import simd

extension ModelData {
    /// Builds `ModelData` directly from a `LiveLinkMessage`, reusing the same in-memory
    /// `ThreeMF.Model`/`Mesh` geometry pipeline `ModelData.init(url:)` uses once it's finished
    /// parsing a file (`ThreeMF.Model.geometry(for:inheritedProperty:)`, `Mesh.edgeGeometries`,
    /// `Mesh.statistics`) — the zip/XML round trip is skipped entirely, nothing about how the
    /// geometry itself gets turned into `SCNGeometry` changes.
    ///
    /// This is a separate, simpler pipeline rather than a refactor of `ModelData.init(url:)` to
    /// share code through `ModelLoader<URL>.LoadedModel`'s more general (multi-file,
    /// nested-component) shape: a LiveLink message is always one flat model with exactly one
    /// component per part, so forcing it through that shape would add real complexity for no
    /// benefit — and `componentProducts` below documents that loading path as deliberately
    /// sensitive to how it's structured, not something to casually reshape.
    public init(liveLink message: LiveLinkMessage, includeEdges: Bool = true) {
        let noInheritance = PartialPropertyReference(groupID: nil, index: nil)

        let parts: [Part] = message.parts.enumerated().map { itemIndex, livePart in
            let (model, mesh) = Self.threeMFModel(for: livePart)
            let geometryResult = model.geometry(for: mesh, inheritedProperty: noInheritance)
            // Cadova writes every part's mesh in world coordinates (no per-part transform to
            // apply), matching how ModelData(url:) sees a plain 3MF item with no matrix either.
            let worldTransform = matrix_identity_double4x4

            let (sharpEdgeLines, smoothEdgeLines): (EdgeLines, EdgeLines)
            if includeEdges {
                let triangleColors = model.explicitTriangleColors(for: mesh)
                (sharpEdgeLines, smoothEdgeLines) = mesh.edgeGeometries(triangleColors: triangleColors)
            } else {
                (sharpEdgeLines, smoothEdgeLines) = (.empty, .empty)
            }

            let stats = mesh.statistics(transform: worldTransform)

            var capVertices: [SIMD3<Float>] = []
            capVertices.reserveCapacity(mesh.vertices.count)
            for vertex in mesh.vertices {
                let world = worldTransform * SIMD4(vertex.simd, 1)
                capVertices.append(SIMD3<Float>(Float(world.x), Float(world.y), Float(world.z)))
            }
            var capIndices: [UInt32] = []
            capIndices.reserveCapacity(mesh.triangles.count * 3)
            for triangle in mesh.triangles {
                capIndices += [UInt32(triangle.v1), UInt32(triangle.v2), UInt32(triangle.v3)]
            }
            let capSolid = capVertices.isEmpty ? nil : PartSolid(vertices: capVertices, indices: capIndices)

            var nodes = Part.Nodes()
            nodes.container.name = "Item \(itemIndex)"

            let dominantColor = geometryResult.dominantColor
            let unknownEdgesNeedLightColor = dominantColor.map(isDarkColor) ?? false
            // Same fallback the file-loading path uses for an unrecognized/missing cadova:semantic
            // attribute (see ThreeMF.Item.semantic in PartSemantic.swift), so an unknown value here
            // degrades the same way a file with the same unknown value would.
            let semantic = PartSemantic(rawValue: livePart.semantic) ?? .solid

            if includeEdges && semantic == .solid {
                let sharpEdgesGroupNode = SCNNode()
                let smoothEdgesGroupNode = SCNNode()
                nodes.sharpEdges = sharpEdgesGroupNode
                nodes.smoothEdges = smoothEdgesGroupNode
                sharpEdgesGroupNode.name = "Sharp edges"
                smoothEdgesGroupNode.name = "Smooth edges"
                nodes.container.addChildNode(sharpEdgesGroupNode)
                nodes.container.addChildNode(smoothEdgesGroupNode)

                let sharpNodeContainer = SCNNode()
                sharpNodeContainer.name = "Sharp edges transformer"
                sharpEdgesGroupNode.addChildNode(sharpNodeContainer)
                let sharpNode = SCNNode(geometry: sharpEdgeLines.geometry(unknownNeedsLightColor: unknownEdgesNeedLightColor))
                sharpNode.name = "Sharp edges geometry"
                sharpNodeContainer.addChildNode(sharpNode)

                let smoothNodeContainer = SCNNode()
                smoothNodeContainer.name = "Smooth edges transformer"
                smoothEdgesGroupNode.addChildNode(smoothNodeContainer)
                let smoothNode = SCNNode(geometry: smoothEdgeLines.geometry(unknownNeedsLightColor: unknownEdgesNeedLightColor))
                smoothNode.name = "Smooth edges geometry"
                smoothNodeContainer.addChildNode(smoothNode)
            }

            let modelNode = SCNNode(geometry: geometryResult.geometry)
            modelNode.name = "Main geometry"
            nodes.model.addChildNode(modelNode)
            let modelGeometryVariants = [ModelGeometryVariant(
                node: modelNode,
                flat: geometryResult.geometry,
                mesh: mesh,
                emittedCorners: geometryResult.emittedCorners
            )]

            return Part(
                nodes: nodes,
                itemIndex: itemIndex,
                name: livePart.name,
                id: nil,
                semantic: semantic,
                stats: stats,
                modelGeometryVariants: modelGeometryVariants,
                dominantColor: dominantColor,
                hasMaterial: geometryResult.hasMaterial,
                capSolid: capSolid
            )
        }

        let container = SCNNode()
        container.name = "Model root"
        for part in parts {
            container.addChildNode(part.nodes.container)
        }

        let (boundsMin, boundsMax) = container.boundingBox
        let boundingBoxSize = SIMD3(
            Double(boundsMax.x - boundsMin.x),
            Double(boundsMax.y - boundsMin.y),
            Double(boundsMax.z - boundsMin.z)
        )

        self = Self(
            rootNode: container,
            parts: parts,
            metadata: message.metadata.threeMFMetadata,
            boundingBoxSize: boundingBoxSize,
            hasAnyMaterials: parts.contains { $0.hasMaterial }
        )
    }

    /// Reconstructs an in-memory `ThreeMF.Model` (with `ColorGroup`/`MetallicDisplayProperties`
    /// resources) and `Mesh` from a LiveLink part's flat wire data, mirroring what Cadova's
    /// `ThreeMFDataProvider.makeModel` builds on the sending side — just reading pre-resolved
    /// bytes instead of calling `meshGL()`. Every triangle gets its material baked in directly
    /// (falling back to the part's default), so no property inheritance is needed when this feeds
    /// into `geometry(for:inheritedProperty:)`.
    private static func threeMFModel(for part: LiveLinkMessage.Part) -> (ThreeMF.Model, ThreeMF.Mesh) {
        let vertices: [ThreeMF.Mesh.Vertex] = stride(from: 0, to: part.vertices.count, by: 3).map { i in
            ThreeMF.Mesh.Vertex(x: part.vertices[i], y: part.vertices[i + 1], z: part.vertices[i + 2])
        }

        var colorGroup = ColorGroup(id: 1)
        var metallicProperties = MetallicDisplayProperties(id: 2)
        var metallicColorGroup = ColorGroup(id: 3, displayPropertiesID: metallicProperties.id)

        // `part.materials` is already the deduplicated palette the sender built; each entry maps
        // 1:1 to a resource here, so there's no need to dedupe again on this side.
        let referenceByMaterialIndex: [PropertyReference] = part.materials.map { entry in
            let color = ThreeMF.Color(red: entry.color.red, green: entry.color.green, blue: entry.color.blue, alpha: entry.color.alpha)
            if let metallicness = entry.metallicness, let roughness = entry.roughness {
                let metallic = Metallic(
                    name: entry.name ?? "Metallic \(metallicProperties.metallics.count + 1)",
                    metallicness: metallicness,
                    roughness: roughness
                )
                metallicProperties.addMetallic(metallic)
                let colorIndex = metallicColorGroup.addColor(color)
                return PropertyReference(groupID: metallicColorGroup.id, index: colorIndex)
            } else {
                let colorIndex = colorGroup.addColor(color)
                return PropertyReference(groupID: colorGroup.id, index: colorIndex)
            }
        }

        func reference(for materialIndex: Int32) -> PropertyReference? {
            guard materialIndex >= 0, Int(materialIndex) < referenceByMaterialIndex.count else { return nil }
            return referenceByMaterialIndex[Int(materialIndex)]
        }

        var triangles: [ThreeMF.Mesh.Triangle] = []
        triangles.reserveCapacity(part.triangleMaterialIndices.count)
        for (triangleIndex, materialIndex) in part.triangleMaterialIndices.enumerated() {
            let resolvedIndex = materialIndex >= 0 ? materialIndex : (part.defaultMaterialIndex ?? -1)
            let propertyRef = reference(for: resolvedIndex)
            let base = triangleIndex * 3
            triangles.append(ThreeMF.Mesh.Triangle(
                v1: Int(part.triangles[base]), v2: Int(part.triangles[base + 1]), v3: Int(part.triangles[base + 2]),
                propertyIndex: propertyRef.map { .uniform($0.index) },
                propertyGroup: propertyRef?.groupID
            ))
        }

        let mesh = ThreeMF.Mesh(vertices: vertices, triangles: triangles)

        var resources: [any ThreeMF.Resource] = []
        if !colorGroup.colors.isEmpty {
            resources.append(colorGroup)
        }
        if !metallicColorGroup.colors.isEmpty {
            resources.append(metallicProperties)
            resources.append(metallicColorGroup)
        }

        let model = ThreeMF.Model(unit: .millimeter, resources: resources)
        return (model, mesh)
    }
}

/// Mirrors Cadova's `Metadata.threeMFMetadata` on the sending side, so a LiveLink push's
/// metadata maps onto the same `ThreeMF.Metadata.Name` cases a full file load would produce.
fileprivate extension LiveLinkMessage.Metadata {
    var threeMFMetadata: [ThreeMF.Metadata] {
        [
            title.map { .init(name: .title, value: $0) },
            description.map { .init(name: .description, value: $0) },
            author.map { .init(name: .designer, value: $0) },
            license.map { .init(name: .licenseTerms, value: $0) },
            date.map { .init(name: .creationDate, value: $0) },
            application.map { .init(name: .application, value: $0) }
        ].compactMap { $0 }
    }
}

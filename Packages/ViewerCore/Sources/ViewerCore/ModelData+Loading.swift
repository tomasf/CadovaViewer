import Foundation
import Dispatch
import ThreeMF
import SceneKit
import AppKit

// The synchronous products of processing a single component, assembled concurrently by
// `ModelData.init` and then consumed on the calling task to build the scene graph.
private struct ComponentProducts: Sendable {
    let mainGeometry: SCNGeometry
    let sharpEdgeLines: EdgeLines
    let smoothEdgeLines: EdgeLines
    let mesh: ThreeMF.Mesh
    let emittedCorners: [Int32]
    let stats: ModelData.Statistics
    let transform: SCNMatrix4
    let dominantColor: SIMD4<Float>?
    let hasMaterial: Bool
    let capVertices: [SIMD3<Float>]
    let capIndices: [UInt32]
}

extension ModelData {
    public init(url: URL, includeEdges: Bool = true) async throws {
        let loader = ModelLoader(url: url)
        let loadedModel = try await loader.load()

        // Scale from the document's modelling unit to millimetres; applied both as the root
        // node's transform and when measuring real-world area/volume/dimensions.
        let multiplier = loadedModel.rootModel.unit?.millimetersPerUnit ?? 1
        let unitScale = simd_double4x4(diagonal: SIMD4(Double(multiplier), Double(multiplier), Double(multiplier), 1))

        // Edge lines are classified once per unique mesh, by each edge's own bordering triangles
        // (see `edgeGeometries(triangleColors:)`) — independent of which part instances the mesh,
        // so this is shared even when the same mesh is placed multiple times with different colours.
        let indexedEdgeLines: [(sharp: EdgeLines, smooth: EdgeLines)]
        if includeEdges {
            indexedEdgeLines = await loadedModel.meshes.asyncMap { loadedMesh in
                let model = loadedModel.models[loadedMesh.modelIndex]
                let triangleColors = model.explicitTriangleColors(for: loadedMesh.mesh)
                return loadedMesh.mesh.edgeGeometries(triangleColors: triangleColors)
            }
        } else {
            indexedEdgeLines = []
        }

        let parts = await Array(loadedModel.items.enumerated()).asyncMap { itemIndex, loadedItem in
            let products = loadedItem.components.map { loadedComponent in
                Self.componentProducts(
                    for: loadedComponent,
                    loadedModel: loadedModel,
                    unitScale: unitScale,
                    includeEdges: includeEdges,
                    indexedEdgeLines: indexedEdgeLines
                )
            }

            var nodes = Part.Nodes()
            nodes.container.name = "Item \(itemIndex)"

            // The part's cap colour is the dominant colour of its heaviest component (most triangles).
            // Also the fallback for edges whose bordering faces rely on this inherited colour rather
            // than an explicit one of their own, since the mesh alone can't classify those.
            let dominantColor = products
                .filter { $0.dominantColor != nil }
                .max { $0.stats.triangleCount < $1.stats.triangleCount }?
                .dominantColor
            let unknownEdgesNeedLightColor = dominantColor.map(isDarkColor) ?? false

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

                    let sharpGeometry = product.sharpEdgeLines.geometry(unknownNeedsLightColor: unknownEdgesNeedLightColor)
                    let sharpNode = SCNNode(geometry: sharpGeometry)
                    sharpNode.name = "Sharp edges geometry"
                    sharpNodeContainer.addChildNode(sharpNode)

                    let smoothNodeContainer = SCNNode()
                    smoothNodeContainer.name = "Smooth edges transformer"
                    smoothNodeContainer.transform = product.transform
                    smoothEdgesGroupNode.addChildNode(smoothNodeContainer)

                    let smoothGeometry = product.smoothEdgeLines.geometry(unknownNeedsLightColor: unknownEdgesNeedLightColor)
                    let smoothNode = SCNNode(geometry: smoothGeometry)
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

            // Concatenate the components' indexed meshes (offsetting indices) into one solid for caps.
            var capVertices: [SIMD3<Float>] = []
            var capIndices: [UInt32] = []
            for product in products {
                let offset = UInt32(capVertices.count)
                capVertices += product.capVertices
                capIndices += product.capIndices.map { $0 + offset }
            }
            let capSolid = capVertices.isEmpty ? nil : PartSolid(vertices: capVertices, indices: capIndices)

            return Part(
                nodes: nodes,
                itemIndex: itemIndex,
                name: loadedItem.rootObject.name ?? "Object \(itemIndex + 1)",
                id: loadedItem.item.partNumber,
                semantic: loadedItem.item.semantic,
                stats: Statistics(products.map(\.stats)),
                modelGeometryVariants: modelGeometryVariants,
                dominantColor: dominantColor,
                hasMaterial: products.contains { $0.hasMaterial },
                capSolid: capSolid
            )
        }

        let container = SCNNode()
        container.name = "Model root"
        container.transform = SCNMatrix4MakeScale(multiplier, multiplier, multiplier)

        for part in parts {
            container.addChildNode(part.nodes.container)
        }

        // `boundingBox` is in the container's local space (children transforms applied, the
        // container's own unit scale not), so multiply by `multiplier` for the mm size.
        let (boundsMin, boundsMax) = container.boundingBox
        let boundingBoxSize = SIMD3(
            Double(boundsMax.x - boundsMin.x),
            Double(boundsMax.y - boundsMin.y),
            Double(boundsMax.z - boundsMin.z)
        ) * Double(multiplier)

        self = Self(rootNode: container, parts: parts, metadata: loadedModel.rootModel.metadata, boundingBoxSize: boundingBoxSize, hasAnyMaterials: parts.contains { $0.hasMaterial })
    }

    /// Below this many vertices/triangles, chunking overhead isn't worth it for the cap-solid
    /// flatten — same reasoning as `ThreeMFModel.chunkedGeometryTriangleThreshold`. Shared with
    /// `ModelData.init(liveLink:)`'s matching flatten, since both build the same shape of data.
    static let chunkedCapThreshold = 20_000

    // Builds one component's geometry/edges/cap/stats. Extracted from the `components.asyncMap`
    // closure and kept synchronous on purpose: the work does no `await`s, and inlining it into the
    // async task closure gave that coroutine a large frame that the Swift/LLVM coroutine-frame
    // splitter miscompiles (an `EXC_BAD_ACCESS` in `swift_task_dealloc` when tearing the task down,
    // Release-only). A plain function has no coroutine frame, so it sidesteps the bug entirely while
    // still running concurrently across components via `asyncMap`.
    private static func componentProducts(
        for loadedComponent: ModelLoader<URL>.LoadedModel.LoadedComponent,
        loadedModel: ModelLoader<URL>.LoadedModel,
        unitScale: simd_double4x4,
        includeEdges: Bool,
        indexedEdgeLines: [(sharp: EdgeLines, smooth: EdgeLines)]
    ) -> ComponentProducts {
        let property = PartialPropertyReference(groupID: loadedComponent.propertyGroupID, index: loadedComponent.propertyIndex)
        let loadedMesh = loadedModel.meshes[loadedComponent.meshIndex]
        let model = loadedModel.models[loadedMesh.modelIndex]

        let geometryResult = model.geometry(for: loadedMesh.mesh, inheritedProperty: property)

        // Mesh coords → millimetres = unit scale ∘ this component's placement transform.
        let worldTransform = unitScale * simd_double4x4(loadedComponent.scnMatrix)
        let stats = loadedMesh.mesh.statistics(transform: worldTransform)

        // World-space indexed mesh (same space as the scene) for the cross-section cap. Chunked
        // like geometry/edge-line building, but simpler: no vertices are dropped and cap indices
        // reference vertex indices directly, so concatenating chunks in original order needs no
        // offsetting at all.
        let vertexChunks = loadedMesh.mesh.vertices.count.chunkedRanges(threshold: Self.chunkedCapThreshold)
        let vertexStorage = ChunkStorage<[SIMD3<Float>]>(count: vertexChunks.count)
        DispatchQueue.concurrentPerform(iterations: vertexChunks.count) { chunkIndex in
            var chunk: [SIMD3<Float>] = []
            chunk.reserveCapacity(vertexChunks[chunkIndex].count)
            for i in vertexChunks[chunkIndex] {
                let world = worldTransform * SIMD4(loadedMesh.mesh.vertices[i].simd, 1)
                chunk.append(SIMD3<Float>(Float(world.x), Float(world.y), Float(world.z)))
            }
            vertexStorage[chunkIndex] = chunk
        }
        let capVertices = vertexStorage.results.flatMap { $0 }

        let triangleChunks = loadedMesh.mesh.triangles.count.chunkedRanges(threshold: Self.chunkedCapThreshold)
        let indexStorage = ChunkStorage<[UInt32]>(count: triangleChunks.count)
        DispatchQueue.concurrentPerform(iterations: triangleChunks.count) { chunkIndex in
            var chunk: [UInt32] = []
            chunk.reserveCapacity(triangleChunks[chunkIndex].count * 3)
            for i in triangleChunks[chunkIndex] {
                let triangle = loadedMesh.mesh.triangles[i]
                chunk.append(UInt32(triangle.v1))
                chunk.append(UInt32(triangle.v2))
                chunk.append(UInt32(triangle.v3))
            }
            indexStorage[chunkIndex] = chunk
        }
        let capIndices = indexStorage.results.flatMap { $0 }

        let (sharpEdgeLines, smoothEdgeLines): (EdgeLines, EdgeLines)
        if includeEdges && loadedComponent.meshIndex < indexedEdgeLines.count {
            (sharpEdgeLines, smoothEdgeLines) = indexedEdgeLines[loadedComponent.meshIndex]
        } else {
            (sharpEdgeLines, smoothEdgeLines) = (.empty, .empty)
        }

        return ComponentProducts(
            mainGeometry: geometryResult.geometry,
            sharpEdgeLines: sharpEdgeLines,
            smoothEdgeLines: smoothEdgeLines,
            mesh: loadedMesh.mesh,
            emittedCorners: geometryResult.emittedCorners,
            stats: stats,
            transform: loadedComponent.scnMatrix,
            dominantColor: geometryResult.dominantColor,
            hasMaterial: geometryResult.hasMaterial,
            capVertices: capVertices,
            capIndices: capIndices
        )
    }
}

extension simd_double4x4 {
    /// A double-precision matrix matching SceneKit's `simd_float4x4(_:)` layout for an `SCNMatrix4`.
    init(_ m: SCNMatrix4) {
        let f = simd_float4x4(m)
        self.init(
            SIMD4<Double>(f.columns.0),
            SIMD4<Double>(f.columns.1),
            SIMD4<Double>(f.columns.2),
            SIMD4<Double>(f.columns.3)
        )
    }
}

extension ModelLoader.LoadedModel.LoadedComponent {
    var scnMatrix: SCNMatrix4 {
        transforms.reduce(SCNMatrix4Identity) { transform, matrix in
            SCNMatrix4Mult(matrix.scnMatrix, transform)
        }
    }
}

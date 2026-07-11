import Foundation
import ThreeMF
import SceneKit
import AppKit

extension ModelData {
    public init(url: URL, includeEdges: Bool = true) async throws {
        let loader = ModelLoader(url: url)
        let loadedModel = try await loader.load()

        // Scale from the document's modelling unit to millimetres; applied both as the root
        // node's transform and when measuring real-world area/volume/dimensions.
        let multiplier = loadedModel.rootModel.unit?.millimetersPerUnit ?? 1
        let unitScale = simd_double4x4(diagonal: SIMD4(Double(multiplier), Double(multiplier), Double(multiplier), 1))

        struct ComponentProducts: Sendable {
            let mainGeometry: SCNGeometry
            let sharpEdgesGeometry: SCNGeometry
            let smoothEdgesGeometry: SCNGeometry
            let mesh: ThreeMF.Mesh
            let emittedCorners: [Int32]
            let stats: ModelData.Statistics
            let transform: SCNMatrix4
            let dominantColor: SIMD4<Float>?
            let capVertices: [SIMD3<Float>]
            let capIndices: [UInt32]
        }

        let indexedEdgeGeometries: [(sharp: SCNGeometry, smooth: SCNGeometry)]
        if includeEdges {
            indexedEdgeGeometries = await loadedModel.meshes.asyncMap { $0.mesh.edgeGeometries() }
        } else {
            indexedEdgeGeometries = []
        }

        let parts = await Array(loadedModel.items.enumerated()).asyncMap { itemIndex, loadedItem in
            let products = await loadedItem.components.asyncMap { loadedComponent in
                let property = PartialPropertyReference(groupID: loadedComponent.propertyGroupID, index: loadedComponent.propertyIndex)
                let loadedMesh = loadedModel.meshes[loadedComponent.meshIndex]
                let model = loadedModel.models[loadedMesh.modelIndex]

                let (geometry, emittedCorners, dominantColor) = model.geometry(for: loadedMesh.mesh, inheritedProperty: property)

                // Mesh coords → millimetres = unit scale ∘ this component's placement transform.
                let worldTransform = unitScale * simd_double4x4(loadedComponent.scnMatrix)
                let stats = loadedMesh.mesh.statistics(transform: worldTransform)

                // World-space indexed mesh (same space as the scene) for the cross-section cap.
                var capVertices: [SIMD3<Float>] = []
                capVertices.reserveCapacity(loadedMesh.mesh.vertices.count)
                for vertex in loadedMesh.mesh.vertices {
                    let world = worldTransform * SIMD4(vertex.simd, 1)
                    capVertices.append(SIMD3<Float>(Float(world.x), Float(world.y), Float(world.z)))
                }
                var capIndices: [UInt32] = []
                capIndices.reserveCapacity(loadedMesh.mesh.triangles.count * 3)
                for triangle in loadedMesh.mesh.triangles {
                    capIndices += [UInt32(triangle.v1), UInt32(triangle.v2), UInt32(triangle.v3)]
                }

                if includeEdges && loadedComponent.meshIndex < indexedEdgeGeometries.count {
                    let (sharp, smooth) = indexedEdgeGeometries[loadedComponent.meshIndex]
                    return ComponentProducts(
                        mainGeometry: geometry,
                        sharpEdgesGeometry: sharp,
                        smoothEdgesGeometry: smooth,
                        mesh: loadedMesh.mesh,
                        emittedCorners: emittedCorners,
                        stats: stats,
                        transform: loadedComponent.scnMatrix,
                        dominantColor: dominantColor,
                        capVertices: capVertices,
                        capIndices: capIndices
                    )
                } else {
                    let emptyGeometry = SCNGeometry()
                    return ComponentProducts(
                        mainGeometry: geometry,
                        sharpEdgesGeometry: emptyGeometry,
                        smoothEdgesGeometry: emptyGeometry,
                        mesh: loadedMesh.mesh,
                        emittedCorners: emittedCorners,
                        stats: stats,
                        transform: loadedComponent.scnMatrix,
                        dominantColor: dominantColor,
                        capVertices: capVertices,
                        capIndices: capIndices
                    )
                }
            }

            var nodes = Part.Nodes()
            nodes.container.name = "Item \(itemIndex)"

            // The part's cap colour is the dominant colour of its heaviest component (most triangles).
            // Also used to decide the edge line colour: black edges disappear against a near-black
            // part, so those get light edges instead.
            let dominantColor = products
                .filter { $0.dominantColor != nil }
                .max { $0.stats.triangleCount < $1.stats.triangleCount }?
                .dominantColor
            let usesLightEdges = dominantColor.map(isDarkColor) ?? false

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

                    let sharpGeometry = usesLightEdges ? recoloredEdgeGeometry(product.sharpEdgesGeometry, color: darkPartEdgeColor) : product.sharpEdgesGeometry
                    let sharpNode = SCNNode(geometry: sharpGeometry)
                    sharpNode.name = "Sharp edges geometry"
                    sharpNodeContainer.addChildNode(sharpNode)

                    let smoothNodeContainer = SCNNode()
                    smoothNodeContainer.name = "Smooth edges transformer"
                    smoothNodeContainer.transform = product.transform
                    smoothEdgesGroupNode.addChildNode(smoothNodeContainer)

                    let smoothGeometry = usesLightEdges ? recoloredEdgeGeometry(product.smoothEdgesGeometry, color: darkPartEdgeColor) : product.smoothEdgesGeometry
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

        self = Self(rootNode: container, parts: parts, metadata: loadedModel.rootModel.metadata, boundingBoxSize: boundingBoxSize)
    }
}

/// Whether `color` (linear RGBA) reads as dark enough that black edge lines would disappear
/// against it. Relative luminance using Rec. 709 coefficients.
private func isDarkColor(_ color: SIMD4<Float>) -> Bool {
    0.2126 * color.x + 0.7152 * color.y + 0.0722 * color.z < 0.05
}

/// Edge line colour used on parts too dark for black edges to read against.
private let darkPartEdgeColor = NSColor(white: 0.5, alpha: 1)

/// A copy of an edge geometry with its material swapped to a flat `color`. Rebuilt with
/// `SCNGeometry(sources:elements:)` rather than mutating `geometry`'s material in place, since
/// `geometry` may be the one shared instance backing every part that reuses this mesh (edge
/// geometries are built once per unique mesh) — mutating it would recolor every other part's
/// edges too.
private func recoloredEdgeGeometry(_ geometry: SCNGeometry, color: NSColor) -> SCNGeometry {
    let newGeometry = SCNGeometry(sources: geometry.sources(for: .vertex), elements: geometry.elements)
    let material = SCNMaterial()
    material.lightingModel = .constant
    material.diffuse.contents = color
    newGeometry.materials = [material]
    return newGeometry
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

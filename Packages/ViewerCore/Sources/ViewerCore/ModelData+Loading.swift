import Foundation
import ThreeMF
import SceneKit
import AppKit

extension ModelData {
    public init(url: URL, includeEdges: Bool = true) async throws {
        let loader = ModelLoader(url: url)
        let loadedModel = try await loader.load()

        struct ComponentProducts: Sendable {
            let mainGeometry: SCNGeometry
            let sharpEdgesGeometry: SCNGeometry
            let smoothEdgesGeometry: SCNGeometry
            let mesh: ThreeMF.Mesh
            let emittedCorners: [Int32]
            let stats: ModelData.Statistics
            let transform: SCNMatrix4
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

                let (geometry, emittedCorners) = model.geometry(for: loadedMesh.mesh, inheritedProperty: property)

                if includeEdges && loadedComponent.meshIndex < indexedEdgeGeometries.count {
                    let (sharp, smooth) = indexedEdgeGeometries[loadedComponent.meshIndex]
                    return ComponentProducts(
                        mainGeometry: geometry,
                        sharpEdgesGeometry: sharp,
                        smoothEdgesGeometry: smooth,
                        mesh: loadedMesh.mesh,
                        emittedCorners: emittedCorners,
                        stats: loadedMesh.mesh.statistics,
                        transform: loadedComponent.scnMatrix
                    )
                } else {
                    let emptyGeometry = SCNGeometry()
                    return ComponentProducts(
                        mainGeometry: geometry,
                        sharpEdgesGeometry: emptyGeometry,
                        smoothEdgesGeometry: emptyGeometry,
                        mesh: loadedMesh.mesh,
                        emittedCorners: emittedCorners,
                        stats: loadedMesh.mesh.statistics,
                        transform: loadedComponent.scnMatrix
                    )
                }
            }

            var nodes = Part.Nodes()
            nodes.container.name = "Item \(itemIndex)"

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

                    let sharpNode = SCNNode(geometry: product.sharpEdgesGeometry)
                    sharpNode.name = "Sharp edges geometry"
                    sharpNodeContainer.addChildNode(sharpNode)

                    let smoothNodeContainer = SCNNode()
                    smoothNodeContainer.name = "Smooth edges transformer"
                    smoothNodeContainer.transform = product.transform
                    smoothEdgesGroupNode.addChildNode(smoothNodeContainer)

                    let smoothNode = SCNNode(geometry: product.smoothEdgesGeometry)
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

            return Part(
                nodes: nodes,
                name: loadedItem.rootObject.name ?? "Object \(itemIndex + 1)",
                id: loadedItem.item.partNumber,
                semantic: loadedItem.item.semantic,
                stats: Statistics(products.map(\.stats)),
                modelGeometryVariants: modelGeometryVariants
            )
        }

        let container = SCNNode()
        container.name = "Model root"
        if let multiplier = loadedModel.rootModel.unit?.millimetersPerUnit {
            container.transform = SCNMatrix4MakeScale(multiplier, multiplier, multiplier)
        }

        for part in parts {
            container.addChildNode(part.nodes.container)
        }

        self = Self(rootNode: container, parts: parts, metadata: loadedModel.rootModel.metadata)
    }
}

extension ModelLoader.LoadedModel.LoadedComponent {
    var scnMatrix: SCNMatrix4 {
        transforms.reduce(SCNMatrix4Identity) { transform, matrix in
            SCNMatrix4Mult(matrix.scnMatrix, transform)
        }
    }
}

import SceneKit

extension SCNView {
    public func applyEdgeDepthOffset(edgeNodes: [SCNNode], cameraNode: SCNNode, modelNode: SCNNode, viewSize: CGSize) {
        // Clear last frame's offset first so the edges sit on the surface during hit
        // testing. The closest hit is then either the surface or a coincident edge — same
        // distance either way — so we can use the cheap closest-hit search without sorting
        // every intersection (`.all`) or filtering edges out.
        for node in edgeNodes {
            node.simdPosition = .zero
        }

        let hitTestPoints: [CGPoint] = [
            CGPoint(x: viewSize.width / 2, y: viewSize.height / 2),
            CGPoint(x: 0, y: 0),
            CGPoint(x: viewSize.width, y: 0),
            CGPoint(x: viewSize.width, y: viewSize.height),
            CGPoint(x: 0, y: viewSize.height),
        ]
        var closestHitTestDistance: Float = 1000.0
        for viewPoint in hitTestPoints {
            let hit = hitTest(viewPoint, options: [
                .searchMode: SCNHitTestSearchMode.closest.rawValue as NSNumber,
                .rootNode: modelNode
            ]).first
            if let hit {
                closestHitTestDistance = min(
                    Float(hit.worldCoordinates.distance(from: cameraNode.presentation.worldPosition)),
                    closestHitTestDistance
                )
            }
        }
        for node in edgeNodes {
            let distanceToPart = Float(cameraNode.presentation.worldPosition.distance(from: node.worldPosition))
            let minDistance = min(closestHitTestDistance, distanceToPart)
            node.simdWorldPosition += cameraNode.presentation.simdWorldFront * (minDistance / -1000.0)
        }
    }
}

import Foundation
import SceneKit

final class ViewportGrid {
    private let coarseGrid = SCNNode()
    private let fineGrid = SCNNode()

    init(container: SCNNode, categoryID: Int) {
        coarseGrid.name = "Coarse grid"
        coarseGrid.categoryBitMask = 1 << categoryID
        fineGrid.name = "Fine grid"
        fineGrid.categoryBitMask = 1 << categoryID

        container.addChildNode(coarseGrid)
        container.addChildNode(fineGrid)

        let originLineContainer = SCNNode()
        container.addChildNode(originLineContainer)

        let extent = 10000.0
        let x = SCNNode(geometry: .lines([(SCNVector3(-extent, 0, 0), SCNVector3(extent, 0, 0))], color: .init(white: 0.5, alpha: 1)))
        let y = SCNNode(geometry: .lines([(SCNVector3(0, -extent, 0), SCNVector3(0, extent, 0))], color: .init(white: 0.5, alpha: 1)))
        let z = SCNNode(geometry: .lines([(SCNVector3(0, 0, -extent), SCNVector3(0, 0, extent))], color: .init(white: 0.5, alpha: 1)))
        originLineContainer.addChildNode(x)
        originLineContainer.addChildNode(y)
        originLineContainer.addChildNode(z)
    }

    func updateVisibility(cameraNode: SCNNode) {
        let z = cameraNode.presentation.convertVector(SCNVector3(0, 0, -1), from: nil).z
        let hideGrid = z > 0 && cameraNode.camera!.usesOrthographicProjection
        coarseGrid.isHidden = hideGrid
        fineGrid.isHidden = hideGrid
    }

    func updateScale(renderer: SCNSceneRenderer, viewSize: CGSize) {
        let bounds = CGRect(origin: .zero, size: viewSize)
        let effectiveScale = min(max(calculateGridScale(renderer: renderer, sceneViewBounds: bounds), 0.11), 99.99)
        setScale(effectiveScale)
    }

   // MARK: - Calculation

    private func calculateGridScale(renderer: SCNSceneRenderer, sceneViewBounds: CGRect) -> Double {
        let topLeft = CGPoint(x: sceneViewBounds.minX, y: sceneViewBounds.minY)
        let topRight = CGPoint(x: sceneViewBounds.maxX, y: sceneViewBounds.minY)
        let bottomLeft = CGPoint(x: sceneViewBounds.minX, y: sceneViewBounds.maxY)
        let bottomRight = CGPoint(x: sceneViewBounds.maxX, y: sceneViewBounds.maxY)

        let topLeftScale = gridScale(renderer: renderer, at: topLeft)
        let topRightScale = gridScale(renderer: renderer, at: topRight)
        let bottomLeftScale = gridScale(renderer: renderer, at: bottomLeft)
        let bottomRightScale = gridScale(renderer: renderer, at: bottomRight)

        return max(topLeftScale, topRightScale, bottomLeftScale, bottomRightScale)
    }

    private func gridScale(renderer: SCNSceneRenderer, at viewPoint: CGPoint) -> Double {
        let gridCenter = renderer.xyPlanePoint(forViewPoint: viewPoint)
        let gridNeighbor = SCNVector3(gridCenter.x + 1, gridCenter.y + 1, 0)

        let projectedCenter = renderer.projectPoint(gridCenter)
        let projectedNeighbor = renderer.projectPoint(gridNeighbor)
        return projectedCenter.distance(from: projectedNeighbor) / 2.squareRoot()
    }

    // MARK: - Construction

    private func setScale(_ scale: Double) {
        let lineDistance = 1 / pow(10, floor(log10(scale)) - 2)
        let fraction = 1 - (ceil(log10(scale)) - log10(scale))

        guard !lineDistance.isNaN else { return }

        let fullOpacity = 0.15
        let coarseCount = 100
        coarseGrid.geometry = makeGrid(lineDistance: lineDistance, count: coarseCount, color: .init(white: 1, alpha: fullOpacity))
        fineGrid.geometry = makeGrid(lineDistance: lineDistance / 10.0, count: coarseCount * 10, color: .init(white: 1, alpha: fraction * fullOpacity))
    }

    private func makeGrid(lineDistance: Double, count: Int, color: NSColor) -> SCNGeometry {
        let range = -Double(count)*lineDistance...Double(count)*lineDistance
        let a = stride(from: range.lowerBound, through: range.upperBound, by: lineDistance).map { y in
            (SCNVector3(range.lowerBound, y, 0), SCNVector3(range.upperBound, y, 0))
        }
        let b = stride(from: range.lowerBound, through: range.upperBound, by: lineDistance).map { x in
            (SCNVector3(x, range.lowerBound, 0), SCNVector3(x, range.upperBound, 0))
        }

        return SCNGeometry.lines(a + b, color: color)
    }
}

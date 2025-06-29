import Foundation
import SceneKit

final class ViewportGrid {
    let node = SCNNode()
    private let originCross = SCNNode()
    private let gridContainer = SCNNode()
    private let perimeter = SCNNode()
    private let coarseGrid = SCNNode()
    private let fineGrid = SCNNode()

    private var currentCoarseSpacing = 0.0
    private var gridCenter = SCNVector3Zero
    private var gridRadius = 0.0

    var showGrid = true { didSet { updateVisibility() }}
    var showOrigin = true { didSet { updateVisibility() }}
    private var cameraHidesGrid = false

    private let maxGridOpacity = 0.15

    init(categoryID: Int) {
        node.name = "Grid"

        coarseGrid.name = "Coarse grid"
        coarseGrid.treeCategoryBitMask = 1 << categoryID
        fineGrid.name = "Fine grid"
        fineGrid.treeCategoryBitMask = 1 << categoryID

        node.addChildNode(gridContainer)
        gridContainer.addChildNode(coarseGrid)
        gridContainer.addChildNode(fineGrid)
        gridContainer.addChildNode(perimeter)
        node.addChildNode(originCross)

        let extent = 10000.0
        let pairs = [
            (SCNVector3(-extent, 0, 0), SCNVector3(extent, 0, 0)),
            (SCNVector3(0, -extent, 0), SCNVector3(0, extent, 0)),
            (SCNVector3(0, 0, -extent), SCNVector3(0, 0, extent))
        ]

        originCross.geometry = .lines(pairs, color: .init(white: 0.4, alpha: 1))
        updateVisibility()
    }

    func updateBounds(geometry: SCNNode) {
        let box = geometry.boundingBox
        let modelRadius = sqrt(pow(box.max.x - box.min.x, 2) + pow(box.max.y - box.min.y, 2)) * 0.5
        let modelCenter = SCNVector3(
            (box.min.x + box.max.x) / 2,
            (box.min.y + box.max.y) / 2,
            (box.min.z + box.max.z) / 2
        )

        gridRadius = ceil(Double(modelRadius * 1.5) / 20.0) * 20.0
        gridCenter = SCNVector3(round(modelCenter.x / 10.0) * 10, round(modelCenter.y / 10.0) * 10, 0)
        currentCoarseSpacing = 0 // Invalidate grid

        let resolution = 100
        let perimeterLines = (0..<resolution).map {
            let angle = Double($0) * .pi * 2 / Double(resolution)
            return SCNVector3(
                gridCenter.x + cos(angle) * gridRadius,
                gridCenter.y + sin(angle) * gridRadius,
                gridCenter.z
            )
        }.wrappedPairs()

        perimeter.geometry = .lines(perimeterLines, color: .init(white: 1, alpha: maxGridOpacity))
    }

    func updateVisibility(cameraNode: SCNNode) {
        let z = cameraNode.presentation.convertVector(SCNVector3(0, 0, -1), from: nil).z
        cameraHidesGrid = z > 0 && cameraNode.camera!.usesOrthographicProjection
        updateVisibility()
    }

    private func updateVisibility() {
        gridContainer.isHidden = cameraHidesGrid || !showGrid
        originCross.isHidden = !showOrigin
    }

    func updateScale(renderer: SCNSceneRenderer, viewSize: CGSize) {
        let bounds = CGRect(origin: .zero, size: viewSize)
        let effectiveScale = min(max(calculateGridScale(renderer: renderer, sceneViewBounds: bounds), 0.11), 400.0)
        buildGrid(effectiveScale)
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

    private func buildGrid(_ scale: Double) {
        guard gridRadius > 0 else { return }
        let lineDistance = 1 / pow(10, floor(log10(scale)) - 2)
        let fraction = 1 - (ceil(log10(scale)) - log10(scale))

        guard !lineDistance.isNaN else { return }

        let fineGridColor = NSColor(white: 1, alpha: fraction * maxGridOpacity)

        if lineDistance != currentCoarseSpacing {
            coarseGrid.geometry = makeGridGeometry(lineDistance: lineDistance, color: .init(white: 1, alpha: maxGridOpacity))
            fineGrid.geometry = makeGridGeometry(lineDistance: lineDistance / 10.0, color: fineGridColor)
            currentCoarseSpacing = lineDistance
        } else {
            fineGrid.geometry?.firstMaterial?.diffuse.contents = fineGridColor
        }
    }

    private func makeGridGeometry(lineDistance: Double, color: NSColor) -> SCNGeometry {
        let minX = ceil((gridCenter.x - gridRadius) / lineDistance) * lineDistance
        let maxX = floor((gridCenter.x + gridRadius) / lineDistance) * lineDistance
        let yLines = stride(from: minX, through: maxX, by: lineDistance).map { x in
            let xOffset = x - gridCenter.x
            let yOffset = sqrt(gridRadius * gridRadius - xOffset * xOffset)
            return (
                SCNVector3(x, gridCenter.y - yOffset, gridCenter.z),
                SCNVector3(x, gridCenter.y + yOffset, gridCenter.z)
            )
        }

        let minY = ceil((gridCenter.y - gridRadius) / lineDistance) * lineDistance
        let maxY = floor((gridCenter.y + gridRadius) / lineDistance) * lineDistance
        let xLines = stride(from: minY, through: maxY, by: lineDistance).map { y in
            let yOffset = y - gridCenter.y
            let xOffset = sqrt(gridRadius * gridRadius - yOffset * yOffset)
            return (
                SCNVector3(gridCenter.x - xOffset, y, gridCenter.z),
                SCNVector3(gridCenter.x + xOffset, y, gridCenter.z)
            )
        }

        return SCNGeometry.lines(xLines + yLines, color: color)
    }
}

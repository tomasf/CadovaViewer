import Foundation
import SceneKit
import AppKit

public final class ViewportGrid {
    public let node = SCNNode()
    private let originCross = SCNNode()
    private let gridContainer = SCNNode()
    private let coarseGrid = SCNNode()
    private let fineGrid = SCNNode()

    private var currentCoarseSpacing = 0.0
    private var gridCenter = SCNVector3Zero
    private var gridRadius = 0.0

    /// Model footprint captured at load time. Used to seed the grid and to bound how far the
    /// view-following disk is allowed to grow at grazing angles.
    private var modelCenter = SCNVector3Zero
    private var modelBaseRadius = 0.0

    public var showGrid = true { didSet { updateVisibility() }}
    public var showOrigin = true { didSet { updateVisibility() }}
    /// Temporarily hides the grid lines while a cross-section plane is on screen (the two grids
    /// overlapping looks messy). Independent of `showGrid` so the user's setting is preserved.
    public var suppressedForCrossSection = false { didSet { updateVisibility() }}
    private var cameraHidesGrid = false

    private let maxGridOpacity = 0.15
    /// Grid lines render at full radial alpha out to this fraction of `gridRadius`, then smoothstep
    /// to zero at the rim so the disk dissolves instead of ending on a hard circle.
    private let fadeStartFraction = 0.6
    /// Each clipped grid line is split into this many segments so the per-vertex radial alpha can
    /// vary smoothly along its length (a 2-vertex line could only fade its endpoints).
    private let lineSubdivisions = 8
    /// Disk radius as a multiple of the camera's distance to the point it's looking at. Big enough
    /// that the solid grid fills a head-on view and only the distant edge fades; small enough to
    /// keep the line count bounded.
    private let focusRadiusFactor = 2.0

    public init() {
        node.name = "Grid"

        coarseGrid.name = "Coarse grid"
        fineGrid.name = "Fine grid"

        node.addChildNode(gridContainer)
        gridContainer.addChildNode(coarseGrid)
        gridContainer.addChildNode(fineGrid)
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

    public func updateBounds(geometry: SCNNode) {
        let box = geometry.boundingBox
        let modelRadius = sqrt(pow(box.max.x - box.min.x, 2) + pow(box.max.y - box.min.y, 2)) * 0.5
        modelCenter = SCNVector3((box.min.x + box.max.x) / 2, (box.min.y + box.max.y) / 2, 0)
        modelBaseRadius = max(ceil(Double(modelRadius * 1.5) / 20.0) * 20.0, 20)

        // Force the next updateScale to recompute the footprint and rebuild from scratch.
        currentCoarseSpacing = 0
        gridRadius = 0
        gridCenter = SCNVector3Zero
    }

    public func updateVisibility(cameraNode: SCNNode) {
        let z = cameraNode.presentation.convertVector(SCNVector3(0, 0, -1), from: nil).z
        cameraHidesGrid = z > 0 && cameraNode.camera!.usesOrthographicProjection
        updateVisibility()
    }

    private func updateVisibility() {
        gridContainer.isHidden = cameraHidesGrid || !showGrid || suppressedForCrossSection
        originCross.isHidden = !showOrigin
    }

    public func updateScale(renderer: SCNSceneRenderer, viewSize: CGSize) {
        guard modelBaseRadius > 0, !gridContainer.isHidden else { return }
        let bounds = CGRect(origin: .zero, size: viewSize)

        let footprintChanged = updateFootprint(renderer: renderer, bounds: bounds)
        let scale = min(max(gridScale(renderer: renderer, at: CGPoint(x: bounds.midX, y: bounds.midY)), 0.11), 400.0)
        buildGrid(scale, footprintChanged: footprintChanged)
    }

   // MARK: - View-following footprint

    /// Centres the disk on the point the camera is looking at (where the centre ray meets z = 0) and
    /// sizes it from the camera's distance to that point, so it tracks pan/zoom smoothly. Returns
    /// whether the change was big enough to warrant rebuilding the geometry — small movements are
    /// absorbed so the grid doesn't churn every frame.
    private func updateFootprint(renderer: SCNSceneRenderer, bounds: CGRect) -> Bool {
        guard let camera = renderer.pointOfView?.presentation else { return false }

        let focus = planeHit(renderer: renderer, viewPoint: CGPoint(x: bounds.midX, y: bounds.midY)) ?? modelCenter
        // Clamp the distance so an extreme grazing angle (focus near the horizon) can't blow the disk
        // up, and a very close zoom still leaves a usable patch.
        let distance = camera.worldPosition.distance(from: focus)
        let clampedDistance = min(max(distance, modelBaseRadius * 0.1), modelBaseRadius * 25)
        let radius = clampedDistance * focusRadiusFactor

        let centerShift = hypot(focus.x - gridCenter.x, focus.y - gridCenter.y)
        let radiusRatio = gridRadius > 0 ? radius / gridRadius : .infinity
        guard gridRadius == 0 || centerShift > gridRadius * 0.1 || radiusRatio > 1.1 || radiusRatio < 0.9 else {
            return false
        }

        gridCenter = SCNVector3(focus.x, focus.y, 0)
        gridRadius = radius
        return true
    }

    /// The point where the ray through `viewPoint` crosses world z = 0, or `nil` if that crossing is
    /// behind the camera or the ray is parallel to the plane (the corner sees the horizon).
    private func planeHit(renderer: SCNSceneRenderer, viewPoint: CGPoint) -> SCNVector3? {
        let start = renderer.unprojectPoint(SCNVector3(viewPoint.x, viewPoint.y, 0))
        let end = renderer.unprojectPoint(SCNVector3(viewPoint.x, viewPoint.y, 1))
        let denominator = end.z - start.z
        guard abs(denominator) > 1e-9 else { return nil }
        let t = -start.z / denominator
        guard t > 0 else { return nil }
        return SCNVector3(start.x + t * (end.x - start.x), start.y + t * (end.y - start.y), 0)
    }

   // MARK: - Density

    /// On-screen pixels per world unit at `viewPoint`, sampled along the world diagonal so it stays
    /// isotropic under rotation.
    private func gridScale(renderer: SCNSceneRenderer, at viewPoint: CGPoint) -> Double {
        let gridPoint = renderer.xyPlanePoint(forViewPoint: viewPoint)
        let neighbor = SCNVector3(gridPoint.x + 1, gridPoint.y + 1, 0)

        let projectedPoint = renderer.projectPoint(gridPoint)
        let projectedNeighbor = renderer.projectPoint(neighbor)
        return projectedPoint.distance(from: projectedNeighbor) / 2.squareRoot()
    }

    // MARK: - Construction

    private func buildGrid(_ scale: Double, footprintChanged: Bool) {
        guard gridRadius > 0 else { return }
        let lineDistance = 1 / pow(10, floor(log10(scale)) - 2)
        guard lineDistance.isFinite, !lineDistance.isNaN else { return }

        // Fine grid fades in across each decade so the LOD transition is seamless: by the time the
        // scale reaches the next power of ten the fine lines are at full strength and become the new
        // coarse grid. The base opacity is baked into the vertex alpha (so crossing lines accumulate
        // like translucent lines should); `node.opacity` carries only this decade fade.
        let fraction = 1 - (ceil(log10(scale)) - log10(scale))
        fineGrid.opacity = min(max(fraction, 0), 1)

        if lineDistance != currentCoarseSpacing || footprintChanged {
            coarseGrid.geometry = makeGridGeometry(lineDistance: lineDistance)
            fineGrid.geometry = makeGridGeometry(lineDistance: lineDistance / 10.0)
            currentCoarseSpacing = lineDistance
        }
    }

    private func makeGridGeometry(lineDistance: Double) -> SCNGeometry {
        var segments: [(SCNVector3, SCNVector3)] = []
        var alphas: [(Double, Double)] = []

        let minX = ceil((gridCenter.x - gridRadius) / lineDistance) * lineDistance
        let maxX = floor((gridCenter.x + gridRadius) / lineDistance) * lineDistance
        for x in stride(from: minX, through: maxX, by: lineDistance) {
            let xOffset = x - gridCenter.x
            let yOffset = sqrt(max(gridRadius * gridRadius - xOffset * xOffset, 0))
            appendLine(
                from: SCNVector3(x, gridCenter.y - yOffset, gridCenter.z),
                to: SCNVector3(x, gridCenter.y + yOffset, gridCenter.z),
                into: &segments, alphas: &alphas
            )
        }

        let minY = ceil((gridCenter.y - gridRadius) / lineDistance) * lineDistance
        let maxY = floor((gridCenter.y + gridRadius) / lineDistance) * lineDistance
        for y in stride(from: minY, through: maxY, by: lineDistance) {
            let yOffset = y - gridCenter.y
            let xOffset = sqrt(max(gridRadius * gridRadius - yOffset * yOffset, 0))
            appendLine(
                from: SCNVector3(gridCenter.x - xOffset, y, gridCenter.z),
                to: SCNVector3(gridCenter.x + xOffset, y, gridCenter.z),
                into: &segments, alphas: &alphas
            )
        }

        return makeLineGeometry(segments: segments, alphas: alphas)
    }

    /// Splits a clipped grid line into `lineSubdivisions` segments and tags each vertex with its
    /// radial alpha so the line fades out as it approaches the rim of the disk.
    private func appendLine(
        from start: SCNVector3, to end: SCNVector3,
        into segments: inout [(SCNVector3, SCNVector3)], alphas: inout [(Double, Double)]
    ) {
        var previous = start
        var previousAlpha = radialAlpha(previous)
        for step in 1...lineSubdivisions {
            let t = Double(step) / Double(lineSubdivisions)
            let point = SCNVector3(
                start.x + (end.x - start.x) * t,
                start.y + (end.y - start.y) * t,
                start.z
            )
            let alpha = radialAlpha(point)
            segments.append((previous, point))
            alphas.append((previousAlpha, alpha))
            previous = point
            previousAlpha = alpha
        }
    }

    private func radialAlpha(_ point: SCNVector3) -> Double {
        let distance = hypot(point.x - gridCenter.x, point.y - gridCenter.y)
        let fadeStart = gridRadius * fadeStartFraction
        if distance <= fadeStart { return 1 }
        if distance >= gridRadius { return 0 }
        let t = (distance - fadeStart) / (gridRadius - fadeStart)
        return 1 - (t * t * (3 - 2 * t)) // 1 - smoothstep
    }

    /// Builds an unlit line geometry whose per-vertex white alpha comes from `alphas`. Layer opacity
    /// (and the fine-grid decade fade) is carried by the node's `opacity`, so it stays a cheap
    /// per-frame property write rather than a geometry rebuild.
    private func makeLineGeometry(segments: [(SCNVector3, SCNVector3)], alphas: [(Double, Double)]) -> SCNGeometry {
        let points = segments.flatMap { [$0.0, $0.1] }
        var colors: [SIMD4<Float>] = []
        colors.reserveCapacity(points.count)
        for alpha in alphas {
            colors.append(SIMD4<Float>(1, 1, 1, Float(alpha.0 * maxGridOpacity)))
            colors.append(SIMD4<Float>(1, 1, 1, Float(alpha.1 * maxGridOpacity)))
        }

        let element = SCNGeometryElement(indices: (0..<points.count).map(Int32.init), primitiveType: .line)
        let vertexSource = SCNGeometrySource(vertices: points)
        let colorData = colors.withUnsafeBytes { Data($0) }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor.white
        geometry.materials = [material]
        return geometry
    }
}

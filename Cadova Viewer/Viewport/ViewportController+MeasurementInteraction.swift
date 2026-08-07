import SceneKit
import AppKit
import simd
import ViewerCore

/// Translates pointer input into world-space points for the measurement tool: plain surface
/// hits, Command corner-snapping, Shift axis-constraint, and the Option centering flag. The
/// `MeasurementController` owns the measurement state; this is purely the hit-testing half.
extension ViewportController {
    func scheduleHoverPointUpdate() {
        guard !hoverPointUpdateScheduled else { return }
        hoverPointUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            hoverPointUpdateScheduled = false
            hoverPointDidChange()
        }
    }

    func hoverPointDidChange() {
        // Update measurement geometry before rendering so the per-frame screen-size
        // scaling in updateAtTime applies to the freshly placed/moved dots.
        if measurementController.interactionMode == .measure {
            let worldPoint = measurementController.isPointerOverList ? nil : hoverPoint.flatMap { measurementPoint(atViewPoint: $0) }
            measurementController.hover(at: worldPoint, centered: measurementIsCentered, sourceViewportID: viewportID)
        }

        updateCrossSectionGizmoHover(at: hoverPoint)

        sceneView.setNeedsRedraw()
        updateNavLibPointerPosition()
    }

    func handleMeasurementClick(at point: CGPoint) {
        guard measurementController.interactionMode == .measure else { return }
        if let worldPoint = measurementPoint(atViewPoint: point) {
            measurementController.commitPoint(at: worldPoint, centered: measurementIsCentered)
            sceneView.setNeedsRedraw()
        }
    }

    /// The world point for the measurement under the cursor. With Shift held while a length
    /// measurement is in progress, the point is constrained to an axis through the anchor
    /// (projected from the cursor ray, so it needn't lie on the model); otherwise it's the model
    /// surface hit (nil if the cursor misses the model).
    private func measurementPoint(atViewPoint point: CGPoint) -> SCNVector3? {
        let modifiers = NSEvent.modifierFlags
        // Command means corners and nothing else: it always yields the nearest visible corner, and
        // yields nothing at all rather than a point mid-face, so a measurement taken this way is
        // corner-to-corner by construction.
        if modifiers.contains(.command) {
            return nearestSnapVertex(toViewPoint: point)
        }
        if modifiers.contains(.shift), let anchor = measurementController.inProgressAnchor {
            return axisConstrainedPoint(atViewPoint: point, from: anchor)
        }
        return surfaceWorldPoint(atViewPoint: point)
    }

    /// Whether the in-progress measurement should be centered on its anchor (Option), placing
    /// its two endpoints at equal distances from the first clicked point. Read live, so pressing
    /// or releasing Option re-shapes the measurement without moving the cursor.
    private var measurementIsCentered: Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    /// The nearest *visible* corner vertex (sharp-edge endpoint) to the cursor, at any distance, or
    /// nil if the model has no corner visible on screen. Corners hidden behind the model are skipped.
    ///
    /// There's deliberately no proximity limit. Snapping is a mode rather than an assist: while the
    /// modifier is held the measurement takes a corner and nothing else, so the cursor only has to
    /// say *which* corner, not land near one.
    private func nearestSnapVertex(toViewPoint point: CGPoint) -> SCNVector3? {
        guard !snapVertices.isEmpty else { return nil }
        ensureSnapGrid()
        guard let bounds = snapGridCellBounds else { return nil }

        let center = SIMD2(Int((Double(point.x) / snapGridCellSize).rounded(.down)),
                           Int((Double(point.y) / snapGridCellSize).rounded(.down)))
        let lastRing = max(max(abs(bounds.min.x - center.x), abs(bounds.max.x - center.x)),
                           max(abs(bounds.min.y - center.y), abs(bounds.max.y - center.y)))

        // Widen a ring of cells at a time, so a corner under the cursor is found without looking at
        // the rest of the model, while a distant one is still reached.
        var candidates: [(index: Int, screen: CGPoint, distance: Double)] = []
        for ring in 0...lastRing {
            forEachCell(inRing: ring, around: center, within: bounds) { cell in
                for entry in snapGridCells[cell] ?? [] {
                    let distance = hypot(Double(entry.screen.x - point.x), Double(entry.screen.y - point.y))
                    candidates.append((entry.index, entry.screen, distance))
                }
            }

            // Every cell not yet visited lies in ring `ring + 1` or beyond, so nothing left can be
            // nearer than this: a visible corner inside that radius is the answer.
            if let nearest = nearestVisibleCandidate(&candidates), nearest.distance <= Double(ring) * snapGridCellSize {
                return nearest.vertex
            }
        }
        // The whole grid has been searched; whatever turned up (if anything) is the nearest visible.
        return nearestVisibleCandidate(&candidates)?.vertex
    }

    /// Sorts `candidates` by distance and returns the closest one that isn't cut away or occluded.
    /// Checking in distance order means the common case — the closest corner faces the camera —
    /// costs a single occlusion check, and usually not even that once the cache is warm.
    private func nearestVisibleCandidate(
        _ candidates: inout [(index: Int, screen: CGPoint, distance: Double)]
    ) -> (vertex: SCNVector3, distance: Double)? {
        candidates.sort { $0.distance < $1.distance }
        return candidates
            .first { !crossSectionHides(snapVertices[$0.index]) && isSnapVertexVisible(at: $0.index, screen: $0.screen) }
            .map { (snapVertices[$0.index], $0.distance) }
    }

    /// Visits the occupied cells whose Chebyshev distance from `center` is exactly `ring` — the
    /// square perimeter at that radius — skipping anything outside the grid's occupied range.
    private func forEachCell(
        inRing ring: Int,
        around center: SIMD2<Int>,
        within bounds: (min: SIMD2<Int>, max: SIMD2<Int>),
        _ body: (SIMD2<Int>) -> Void
    ) {
        func visit(_ x: Int, _ y: Int) {
            guard x >= bounds.min.x, x <= bounds.max.x, y >= bounds.min.y, y <= bounds.max.y else { return }
            body(SIMD2(x, y))
        }
        guard ring > 0 else {
            visit(center.x, center.y)
            return
        }
        for dx in -ring...ring {
            visit(center.x + dx, center.y - ring)
            visit(center.x + dx, center.y + ring)
        }
        for dy in (-ring + 1)...(ring - 1) {
            visit(center.x - ring, center.y + dy)
            visit(center.x + ring, center.y + dy)
        }
    }

    /// Drops the snap grid so the next query rebuilds it. Needed when `snapVertices` itself is
    /// replaced — the grid holds indices into it, and a reloaded model of the same size would
    /// otherwise slip past the checks in `ensureSnapGrid`.
    func invalidateSnapGrid() {
        snapGridCells.removeAll(keepingCapacity: true)
        snapGridCellBounds = nil
        snapVertexVisibility = []
        snapGridViewSize = .zero
    }

    /// Rebuilds the screen-space bucket if anything it's built from has changed since last time;
    /// otherwise reuses it (the common case while hovering with a still camera).
    private func ensureSnapGrid() {
        guard let pointOfView = sceneView.pointOfView, let camera = pointOfView.camera else { return }
        let viewSize = sceneView.bounds.size
        guard viewSize.width > 0, viewSize.height > 0 else { return }

        // The *presentation* transform: that's what SceneKit projects through, so during an animated
        // camera move this tracks where the camera currently appears rather than where it's headed.
        let worldTransform = pointOfView.presentation.worldTransform
        let projection = camera.projectionTransform(withViewportSize: viewSize)
        let hiddenParts = hiddenPartIDs
        let crossSections = activeCrossSections

        if snapGridViewSize == viewSize,
           SCNMatrix4EqualToMatrix4(worldTransform, snapGridWorldTransform),
           SCNMatrix4EqualToMatrix4(projection, snapGridProjection),
           snapGridHiddenPartIDs == hiddenParts,
           snapGridCrossSections == crossSections,
           snapVertexVisibility.count == snapVertices.count {
            return
        }
        snapGridWorldTransform = worldTransform
        snapGridProjection = projection
        snapGridViewSize = viewSize
        snapGridHiddenPartIDs = hiddenParts
        snapGridCrossSections = crossSections
        snapVertexVisibility = Array(repeating: nil, count: snapVertices.count)

        // Project through one matrix rather than calling `sceneView.projectPoint` per corner: that's
        // an Objective-C round trip into the renderer, and a detailed model has tens of thousands of
        // corners, so the per-call overhead alone stalled the first snap after every camera move.
        // `ViewProjection` is checked against `projectPoint` in ViewerCore's tests.
        let viewProjection = ViewProjection(cameraTransform: worldTransform, projectionTransform: projection, viewportSize: viewSize)
        snapGridCells.removeAll(keepingCapacity: true)
        var lowest = SIMD2(Int.max, Int.max)
        var highest = SIMD2(Int.min, Int.min)
        // Corners off screen are never snap targets — the user can't see them to aim at one, and
        // `isVertexVisible` has no surface to test them against so it would wave them through. It
        // also keeps the grid bounded: a corner just in front of the camera projects thousands of
        // points away, which would leave the outward search a huge empty area to cross.
        let visibleArea = CGRect(origin: .zero, size: viewSize).insetBy(dx: -snapGridCellSize, dy: -snapGridCellSize)
        for (index, vertex) in snapVertices.enumerated() {
            guard let screen = viewProjection.project(vertex), visibleArea.contains(screen) else { continue }
            let key = SIMD2(Int((Double(screen.x) / snapGridCellSize).rounded(.down)),
                            Int((Double(screen.y) / snapGridCellSize).rounded(.down)))
            snapGridCells[key, default: []].append((index, screen))
            lowest = SIMD2(min(lowest.x, key.x), min(lowest.y, key.y))
            highest = SIMD2(max(highest.x, key.x), max(highest.y, key.y))
        }
        snapGridCellBounds = snapGridCells.isEmpty ? nil : (lowest, highest)
    }

    /// `isVertexVisible` memoized for the life of the snap grid. The check is a scene hit test —
    /// the expensive part of snapping — and sweeping the cursor over a cluster of corners otherwise
    /// re-tests the same ones on every mouse move. The grid is rebuilt whenever the camera, the
    /// viewport, part visibility, or the cross-sections change, which is everything the answer
    /// depends on, so a cached answer can't go stale.
    private func isSnapVertexVisible(at index: Int, screen: CGPoint) -> Bool {
        guard snapVertexVisibility.indices.contains(index) else { return false }
        if let cached = snapVertexVisibility[index] { return cached }
        let visible = isVertexVisible(snapVertices[index], atScreenPoint: screen)
        snapVertexVisibility[index] = visible
        return visible
    }

    /// Whether a corner vertex is unobstructed from the camera: casts at the vertex's
    /// screen position and checks nothing on the model is meaningfully nearer than it.
    private func isVertexVisible(_ vertex: SCNVector3, atScreenPoint screenPoint: CGPoint) -> Bool {
        guard let cameraNode = sceneView.pointOfView else { return true }
        let cameraPosition = cameraNode.presentation.worldPosition
        let vertexDistance = vertex.distance(from: cameraPosition)

        // Nearest *visible* hit (kept-side geometry or a cap), so clipped-away geometry in front of a
        // cut doesn't count as an occluder. Edge nodes sit on the surface (nudged toward the camera by
        // ~0.1%), so they stay within the tolerance below.
        let nearestHit = nearestVisibleHit(at: screenPoint, in: modelInstance.root)

        // No surface in front of the point (e.g. a silhouette corner) → treat as visible.
        guard let nearestHit else { return true }
        let hitDistance = nearestHit.worldCoordinates.distance(from: cameraPosition)
        return hitDistance >= vertexDistance * 0.98
    }

    /// Projects the cursor ray onto an axis line through `start`, choosing the axis whose
    /// screen-space direction best matches the cursor's movement from the start point.
    private func axisConstrainedPoint(atViewPoint point: CGPoint, from start: SCNVector3) -> SCNVector3? {
        let viewPoint = point

        let startScreen = sceneView.projectPoint(start)
        let screenDelta = simd_double2(Double(viewPoint.x) - Double(startScreen.x), Double(viewPoint.y) - Double(startScreen.y))
        guard simd_length(screenDelta) > 1e-3 else { return start }
        let screenDirection = simd_normalize(screenDelta)

        let startVector = simd_double3(Double(start.x), Double(start.y), Double(start.z))
        let axes: [simd_double3] = [simd_double3(1, 0, 0), simd_double3(0, 1, 0), simd_double3(0, 0, 1)]

        var bestAxis = axes[0]
        var bestScore = -1.0
        for axis in axes {
            let tip = sceneView.projectPoint(SCNVector3(startVector.x + axis.x, startVector.y + axis.y, startVector.z + axis.z))
            let direction = simd_double2(Double(tip.x) - Double(startScreen.x), Double(tip.y) - Double(startScreen.y))
            let length = simd_length(direction)
            guard length > 1e-6 else { continue } // axis points (almost) straight at the camera
            let score = abs(simd_dot(screenDirection, direction / length))
            if score > bestScore {
                bestScore = score
                bestAxis = axis
            }
        }

        // Closest point on the axis line (startVector, bestAxis) to the cursor ray.
        let nearPoint = sceneView.unprojectPoint(SCNVector3(viewPoint.x, viewPoint.y, 0))
        let farPoint = sceneView.unprojectPoint(SCNVector3(viewPoint.x, viewPoint.y, 1))
        let near = simd_double3(Double(nearPoint.x), Double(nearPoint.y), Double(nearPoint.z))
        let rayDirection = simd_double3(Double(farPoint.x), Double(farPoint.y), Double(farPoint.z)) - near
        let offset = startVector - near
        let b = simd_dot(bestAxis, rayDirection)
        let c = simd_dot(rayDirection, rayDirection)
        let denominator = c - b * b // bestAxis·bestAxis == 1
        guard abs(denominator) > 1e-9 else { return nil } // ray parallel to the axis
        let t = (b * simd_dot(rayDirection, offset) - c * simd_dot(bestAxis, offset)) / denominator
        let end = startVector + t * bestAxis
        return SCNVector3(end.x, end.y, end.z)
    }

    /// Casts a ray at the given view point and returns the world coordinates of the
    /// nearest model surface hit, or nil if the ray misses the model. `point` is in
    /// AppKit view coordinates (the `SCNView`'s bottom-left origin), matching
    /// SceneKit's hit-test/project/unproject APIs.
    private func surfaceWorldPoint(atViewPoint point: CGPoint) -> SCNVector3? {
        // The nearest visible surface: kept-side geometry or a cut cap, excluding edges and
        // clipped-away geometry. Hidden parts are skipped via their `isHidden` containers.
        nearestVisibleHit(at: point, in: modelInstance.root)?.worldCoordinates
    }
}

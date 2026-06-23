import SceneKit
import AppKit
import simd
import ViewerCore

/// Translates pointer input into world-space points for the measurement tool: plain surface
/// hits, Option-snapping to feature-edge corners, and Shift axis-constraint. The
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
            measurementController.hover(at: worldPoint, sourceViewportID: viewportID)
        }

        updateCrossSectionGizmoHover(at: hoverPoint)

        sceneView.setNeedsRedraw()
        updateNavLibPointerPosition()
    }

    func handleMeasurementClick(at point: CGPoint) {
        guard measurementController.interactionMode == .measure else { return }
        if let worldPoint = measurementPoint(atViewPoint: point) {
            measurementController.commitPoint(at: worldPoint)
            sceneView.setNeedsRedraw()
        }
    }

    /// The world point for the measurement under the cursor. With Shift held while a
    /// length measurement is in progress, the point is constrained to an axis through the
    /// start point (projected from the cursor ray, so it needn't lie on the model);
    /// otherwise it's the model surface hit (nil if the cursor misses the model).
    private func measurementPoint(atViewPoint point: CGPoint) -> SCNVector3? {
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.option), let vertex = nearestSnapVertex(toViewPoint: point) {
            return vertex
        }
        if modifiers.contains(.shift), let start = measurementController.inProgressStart {
            return axisConstrainedPoint(atViewPoint: point, from: start)
        }
        return surfaceWorldPoint(atViewPoint: point)
    }

    /// Nearest *visible* corner vertex (sharp-edge endpoint) whose screen projection is
    /// within a small radius of the cursor, or nil if none qualifies. Corners hidden
    /// behind the model are skipped.
    private func nearestSnapVertex(toViewPoint point: CGPoint) -> SCNVector3? {
        guard !snapVertices.isEmpty else { return nil }
        let viewPoint = point
        ensureSnapGrid()

        let threshold = 40.0 // view points (must be <= snapGridCellSize; see nearestSnapVertex's 3x3 search)
        let cellX = Int((Double(viewPoint.x) / snapGridCellSize).rounded(.down))
        let cellY = Int((Double(viewPoint.y) / snapGridCellSize).rounded(.down))

        var nearby: [(vertex: SCNVector3, distance: Double)] = []
        for dx in -1...1 {
            for dy in -1...1 {
                for entry in snapGridCells[SIMD2(cellX + dx, cellY + dy)] ?? [] {
                    let distance = hypot(Double(entry.screen.x - viewPoint.x), Double(entry.screen.y - viewPoint.y))
                    if distance < threshold {
                        nearby.append((entry.vertex, distance))
                    }
                }
            }
        }

        return nearby.sorted { $0.distance < $1.distance }
            .first { !crossSectionHides($0.vertex) && isVertexVisible($0.vertex) }?
            .vertex
    }

    /// Rebuilds the screen-space bucket if the camera or viewport has changed since it was
    /// last built; otherwise reuses it (the common case while hovering with a still camera).
    private func ensureSnapGrid() {
        guard let pointOfView = sceneView.pointOfView else { return }
        let worldTransform = pointOfView.worldTransform
        let projection = pointOfView.camera?.projectionTransform ?? SCNMatrix4Identity

        let viewSize = sceneView.bounds.size
        if snapGridViewSize == viewSize,
           SCNMatrix4EqualToMatrix4(worldTransform, snapGridWorldTransform),
           SCNMatrix4EqualToMatrix4(projection, snapGridProjection) {
            return
        }
        snapGridWorldTransform = worldTransform
        snapGridProjection = projection
        snapGridViewSize = viewSize

        snapGridCells.removeAll(keepingCapacity: true)
        for vertex in snapVertices {
            let projected = sceneView.projectPoint(vertex)
            guard projected.z >= 0, projected.z <= 1 else { continue }
            let key = SIMD2(Int((Double(projected.x) / snapGridCellSize).rounded(.down)),
                            Int((Double(projected.y) / snapGridCellSize).rounded(.down)))
            snapGridCells[key, default: []].append((vertex, CGPoint(x: projected.x, y: projected.y)))
        }
    }

    /// Whether a corner vertex is unobstructed from the camera: casts at the vertex's
    /// screen position and checks nothing on the model is meaningfully nearer than it.
    private func isVertexVisible(_ vertex: SCNVector3) -> Bool {
        guard let cameraNode = sceneView.pointOfView else { return true }
        let cameraPosition = cameraNode.presentation.worldPosition
        let vertexDistance = vertex.distance(from: cameraPosition)

        // Nearest *visible* hit (kept-side geometry or a cap), so clipped-away geometry in front of a
        // cut doesn't count as an occluder. Edge nodes sit on the surface (nudged toward the camera by
        // ~0.1%), so they stay within the tolerance below.
        let screenPoint = sceneView.projectPoint(vertex)
        let nearestHit = nearestVisibleHit(at: CGPoint(x: screenPoint.x, y: screenPoint.y), in: modelInstance.root)

        // No surface in front of the point (e.g. a silhouette corner) → treat as visible.
        guard let nearestHit else { return true }
        let hitDistance = nearestHit.worldCoordinates.distance(from: cameraPosition)
        return hitDistance >= vertexDistance * 0.98
    }

    /// Collects the world-space endpoints of every part's sharp (feature) edges, which are
    /// the genuine corner vertices — flat-surface and smooth-tessellation vertices are
    /// excluded because they don't lie on a sharp edge.
    func gatherSnapVertices() -> [SCNVector3] {
        var seen = Set<SIMD3<Int>>()
        var result: [SCNVector3] = []

        for part in sceneController.parts {
            guard let sharpEdges = part.nodes.sharpEdges else { continue }
            sharpEdges.enumerateHierarchy { node, _ in
                guard let geometry = node.geometry,
                      let source = geometry.sources(for: .vertex).first,
                      let element = geometry.elements.first else { return }

                let vertices = source.decodedVertices()
                for index in Set(element.decodedLineIndices()) where index < vertices.count {
                    let world = node.convertPosition(vertices[index], to: nil)
                    let key = SIMD3<Int>(Int((world.x * 1000).rounded()), Int((world.y * 1000).rounded()), Int((world.z * 1000).rounded()))
                    if seen.insert(key).inserted {
                        result.append(world)
                    }
                }
            }
        }
        return result
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

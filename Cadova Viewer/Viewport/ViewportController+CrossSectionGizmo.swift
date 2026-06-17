import SceneKit
import ViewerCore
import simd

/// Interactive manipulation of the selected cross-section via the gizmo. The scene view calls these
/// in `mouseDown` (before camera control); see `CustomSceneView`.
extension ViewportController {
    /// Begins a drag if a gizmo handle is under `point`. Returns false to let camera control proceed.
    func beginCrossSectionGizmoDrag(at point: CGPoint) -> Bool {
        guard let id = selectedCrossSectionID,
              let section = crossSections.first(where: { $0.id == id }),
              !crossSectionGizmo.root.isHidden else { return false }

        let hits = sceneView.hitTest(point, options: [
            .rootNode: crossSectionGizmo.root,
            .searchMode: SCNHitTestSearchMode.closest.rawValue as NSNumber
        ])
        guard let hit = hits.first, let handle = crossSectionGizmo.handle(for: hit.node) else { return false }

        let ray = worldRay(at: point)
        let pivot = crossSectionGizmoAnchor(for: section) // the gizmo's on-plane anchor, near the view
        let grab: Double
        switch handle {
        case .translate(let axis):
            grab = closestAxisParameter(axisPoint: pivot, axisDirection: worldAxis(axis, of: section), ray: ray)
        case .rotate(let axis):
            grab = rotationAngle(origin: pivot, axis: worldAxis(axis, of: section), ray: ray) ?? 0
        }
        crossSectionDrag = CrossSectionDragState(handle: handle, startSection: section, grab: grab, pivot: pivot)
        crossSectionDragUndoSnapshot = crossSections // for one undo step covering the whole drag
        crossSectionGizmo.setActiveHandle(handle) // dim the other handles
        sceneView.setNeedsRedraw()
        return true
    }

    func updateCrossSectionGizmoDrag(at point: CGPoint) {
        guard let drag = crossSectionDrag,
              let index = crossSections.firstIndex(where: { $0.id == drag.startSection.id }) else { return }

        let ray = worldRay(at: point)
        var section = drag.startSection
        switch drag.handle {
        case .translate(let axis):
            let direction = worldAxis(axis, of: drag.startSection)
            let now = closestAxisParameter(axisPoint: drag.pivot, axisDirection: direction, ray: ray)
            section.origin = drag.pivot + direction * (now - drag.grab)
        case .rotate(let axis):
            let world = worldAxis(axis, of: drag.startSection)
            guard let now = rotationAngle(origin: drag.pivot, axis: world, ray: ray) else { return }
            section.orientation = simd_quatd(angle: now - drag.grab, axis: world) * drag.startSection.orientation
            section.origin = drag.pivot // tilt the plane around the pivot (where you were looking)
        }
        crossSections[index] = section // drives the live overlay + coalesced cap rebuild
    }

    func endCrossSectionGizmoDrag() {
        // Register one undo for the whole drag (the live updates above bypassed undo).
        if let snapshot = crossSectionDragUndoSnapshot, let drag = crossSectionDrag, snapshot != crossSections {
            let actionName: String
            switch drag.handle {
            case .translate: actionName = "Move Cross-Section"
            case .rotate: actionName = "Rotate Cross-Section"
            }
            registerCrossSectionUndo(restoring: snapshot, actionName: actionName)
        }
        crossSectionDragUndoSnapshot = nil
        crossSectionDrag = nil
        crossSectionGizmo.setActiveHandle(nil) // restore all handles
        // Ease the gizmo back to the view centre on its (possibly moved) plane instead of snapping.
        if let id = selectedCrossSectionID, let section = crossSections.first(where: { $0.id == id }) {
            crossSectionGizmo.settle(to: crossSectionGizmoAnchor(for: section), duration: 0.2)
        }
        sceneView.setNeedsRedraw()
    }

    /// A handle's local axis expressed in world space — the gizmo is plane-relative, so handles point
    /// along the plane's rotated axes.
    private func worldAxis(_ axis: CrossSection.Axis, of section: CrossSection) -> SIMD3<Double> {
        simd_normalize(section.orientation.act(axis.unit))
    }

    /// A point on the section's plane near the centre of the view — where the gizmo is anchored so it
    /// stays reachable when zoomed in. Falls back to the stored origin if the plane is edge-on.
    func crossSectionGizmoAnchor(for section: CrossSection) -> SIMD3<Double> {
        let center = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        let ray = worldRay(at: center)
        let normal = section.normal
        let distance = simd_dot(normal, section.origin)
        let denom = simd_dot(ray.direction, normal)
        if abs(denom) > 1e-9 {
            let t = (distance - simd_dot(ray.origin, normal)) / denom
            if t > 0 { return ray.origin + ray.direction * t }
        }
        return section.origin
    }

    // MARK: - Ray math

    /// The world-space ray through a view point (origin on the near plane, unit direction).
    private func worldRay(at point: CGPoint) -> (origin: SIMD3<Double>, direction: SIMD3<Double>) {
        let near = sceneView.unprojectPoint(SCNVector3(point.x, point.y, 0))
        let far = sceneView.unprojectPoint(SCNVector3(point.x, point.y, 1))
        let origin = SIMD3<Double>(Double(near.x), Double(near.y), Double(near.z))
        let direction = SIMD3<Double>(Double(far.x - near.x), Double(far.y - near.y), Double(far.z - near.z))
        return (origin, simd_normalize(direction))
    }

    /// The parameter `s` of the point `axisPoint + s·axisDirection` closest to the ray (for dragging an
    /// origin along a world axis). `axisDirection` must be unit length.
    private func closestAxisParameter(axisPoint: SIMD3<Double>, axisDirection u: SIMD3<Double>, ray: (origin: SIMD3<Double>, direction: SIMD3<Double>)) -> Double {
        let v = ray.direction
        let w0 = axisPoint - ray.origin
        let b = simd_dot(u, v)
        let denom = 1 - b * b // a·c − b² with a = c = 1 (both unit)
        if abs(denom) < 1e-9 { return 0 } // axis ∥ ray
        let d = simd_dot(u, w0)
        let e = simd_dot(v, w0)
        return (b * e - d) / denom
    }

    /// The angle of the cursor around `origin` within the plane normal to `axis` (for rotation drags),
    /// or nil if the ray is parallel to that plane. `axis` must be unit length.
    private func rotationAngle(origin: SIMD3<Double>, axis n: SIMD3<Double>, ray: (origin: SIMD3<Double>, direction: SIMD3<Double>)) -> Double? {
        let denom = simd_dot(ray.direction, n)
        if abs(denom) < 1e-9 { return nil }
        let t = simd_dot(origin - ray.origin, n) / denom
        let hit = ray.origin + ray.direction * t

        let reference = abs(n.x) < 0.9 ? SIMD3<Double>(1, 0, 0) : SIMD3<Double>(0, 1, 0)
        let e1 = simd_normalize(simd_cross(reference, n))
        let e2 = simd_cross(n, e1)
        let d = hit - origin
        return atan2(simd_dot(d, e2), simd_dot(d, e1))
    }
}

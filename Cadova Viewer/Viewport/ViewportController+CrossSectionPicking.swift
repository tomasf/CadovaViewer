import SceneKit
import ViewerCore
import simd

/// Cross-section-aware hit-testing. SceneKit's hit-test does geometric ray intersection and ignores
/// the clip shader, so without this it returns clipped-away ("thin air") geometry. These helpers
/// return the nearest hit that's actually visible through the active cuts — kept-side model geometry
/// or a cap surface — and fall back to the plain fast path when no cuts are active.
extension ViewportController {
    /// Whether a world point is hidden by any active cross-section.
    func crossSectionHides(_ point: SCNVector3) -> Bool {
        let active = activeCrossSections
        guard !active.isEmpty else { return false }
        let p = SIMD3<Double>(Double(point.x), Double(point.y), Double(point.z))
        return active.contains { $0.hides(p) }
    }

    /// Nearest visible hit for a view-space point, ordered by depth (works for perspective and
    /// orthographic). Excludes edge lines and clipped-away geometry; includes the cut caps so a click
    /// on a solid cut face lands on the cut surface rather than the hidden wall behind it.
    func nearestVisibleHit(at viewPoint: CGPoint, in root: SCNNode, includingCaps: Bool = true) -> SCNHitTestResult? {
        guard !activeCrossSections.isEmpty else {
            return sceneView.hitTest(viewPoint, options: [
                .rootNode: root,
                .searchMode: SCNHitTestSearchMode.closest.rawValue as NSNumber
            ]).first { !edgeNodes.contains($0.node) }
        }

        var results = sceneView.hitTest(viewPoint, options: [
            .rootNode: root,
            .searchMode: SCNHitTestSearchMode.all.rawValue as NSNumber
        ])
        if includingCaps {
            results += sceneView.hitTest(viewPoint, options: [
                .rootNode: crossSectionCapNode,
                .searchMode: SCNHitTestSearchMode.all.rawValue as NSNumber
            ])
        }
        return results
            .filter { !edgeNodes.contains($0.node) && !crossSectionHides($0.worldCoordinates) }
            .min { sceneView.projectPoint($0.worldCoordinates).z < sceneView.projectPoint($1.worldCoordinates).z }
    }

    /// Nearest visible hit along a world-space segment (for NavLib), ordered by distance from `origin`.
    func nearestVisibleHit(segmentFrom origin: SCNVector3, to end: SCNVector3, in root: SCNNode, includingCaps: Bool = true) -> SCNHitTestResult? {
        let options: [String: Any] = [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue as NSNumber]
        var results = root.hitTestWithSegment(from: origin, to: end, options: options)
        if includingCaps {
            results += crossSectionCapNode.hitTestWithSegment(from: origin, to: end, options: options)
        }
        return results
            .filter { !edgeNodes.contains($0.node) && !crossSectionHides($0.worldCoordinates) }
            .min { $0.worldCoordinates.distance(from: origin) < $1.worldCoordinates.distance(from: origin) }
    }
}

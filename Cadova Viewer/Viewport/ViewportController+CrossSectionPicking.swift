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
        let searchMode: SCNHitTestSearchMode = activeCrossSections.isEmpty ? .closest : .all
        var results = visiblePartModelNodes.flatMap { node in
            sceneView.hitTest(viewPoint, options: [
                .rootNode: node,
                .searchMode: searchMode.rawValue as NSNumber
            ])
        }
        if includingCaps, shouldHitTestCrossSectionCaps {
            results += sceneView.hitTest(viewPoint, options: [
                .rootNode: crossSectionCapNode,
                .searchMode: SCNHitTestSearchMode.all.rawValue as NSNumber
            ])
        }
        return results
            .compactMap { result -> (result: SCNHitTestResult, depth: Float)? in
                guard !crossSectionHides(result.worldCoordinates),
                      let depth = viewDepth(of: result.worldCoordinates)
                else { return nil }
                return (result, depth)
            }
            .min { $0.depth < $1.depth }?
            .result
    }

    /// Nearest visible hit along a world-space segment (for NavLib), ordered by distance from `origin`.
    func nearestVisibleHit(segmentFrom origin: SCNVector3, to end: SCNVector3, in root: SCNNode, includingCaps: Bool = true) -> SCNHitTestResult? {
        let options: [String: Any] = [SCNHitTestOption.searchMode.rawValue: SCNHitTestSearchMode.all.rawValue as NSNumber]
        var results = visiblePartModelNodes.flatMap { node in
            node.hitTestWithSegment(from: origin, to: end, options: options)
        }
        if includingCaps, shouldHitTestCrossSectionCaps {
            results += crossSectionCapNode.hitTestWithSegment(from: origin, to: end, options: options)
        }
        return results
            .filter { segmentContains($0.worldCoordinates, from: origin, to: end) && !crossSectionHides($0.worldCoordinates) }
            .min { $0.worldCoordinates.distance(from: origin) < $1.worldCoordinates.distance(from: origin) }
    }

    private var visiblePartModelNodes: [SCNNode] {
        sceneController.parts.compactMap { part in
            hiddenPartIDs.contains(part.id) ? nil : modelInstance.partModelNodes[part.id]
        }
    }

    private var shouldHitTestCrossSectionCaps: Bool {
        !activeCrossSections.isEmpty && !crossSectionCapInFlight && !crossSectionCapNeedsRebuild && crossSectionDrag == nil
    }

    private func viewDepth(of point: SCNVector3) -> Float? {
        guard let pointOfView = sceneView.pointOfView?.presentation else { return nil }
        let toPoint = SIMD3<Float>(
            Float(point.x) - pointOfView.simdWorldPosition.x,
            Float(point.y) - pointOfView.simdWorldPosition.y,
            Float(point.z) - pointOfView.simdWorldPosition.z
        )
        let depth = simd_dot(toPoint, simd_normalize(pointOfView.simdWorldFront))
        return depth >= 0 ? depth : nil
    }

    private func segmentContains(_ point: SCNVector3, from origin: SCNVector3, to end: SCNVector3) -> Bool {
        let start = SIMD3<Double>(Double(origin.x), Double(origin.y), Double(origin.z))
        let finish = SIMD3<Double>(Double(end.x), Double(end.y), Double(end.z))
        let p = SIMD3<Double>(Double(point.x), Double(point.y), Double(point.z))
        let segment = finish - start
        let lengthSquared = simd_length_squared(segment)
        guard lengthSquared > 0 else { return false }

        let t = simd_dot(p - start, segment) / lengthSquared
        return t >= -1e-6 && t <= 1 + 1e-6
    }
}

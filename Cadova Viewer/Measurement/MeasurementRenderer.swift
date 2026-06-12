import Foundation
import SceneKit
import Combine
import AppKit
import simd
import ViewerCore

/// Draws one viewport's copy of the document-global measurements. It observes the shared
/// `MeasurementController` and builds dots + connecting lines under `parentNode` (in this
/// viewport's scene), keeping them at a constant on-screen size for this viewport's camera. Every
/// viewport has its own renderer, so the same measurements appear in all of them.
final class MeasurementRenderer {
    private let controller: MeasurementController
    private let parentNode: SCNNode

    /// Called when the geometry changes and a redraw is needed. Set by the viewport.
    var onVisualChange: (() -> Void)?

    /// Desired on-screen radii (in view points), kept constant regardless of zoom.
    private let dotScreenRadius = 4.5
    private let lineScreenRadius = 1.6

    private struct MeasurementNodes {
        let container: SCNNode
        /// Dots and line that need per-frame on-screen-size scaling. Captured once when
        /// the geometry is (re)built, so the render thread never walks the live scene
        /// graph (`childNodes`) while the main thread mutates it.
        let scalables: [SCNNode]
        /// Subtle dashed line drawn on top of the model (no depth testing) so the part of
        /// the measurement occluded by the model stays faintly visible. Its dash geometry
        /// is rebuilt per frame for a constant on-screen dash size.
        let overlayLine: SCNNode?
        let start: SCNVector3
        let end: SCNVector3?
        let color: NSColor
    }

    /// Keyed by measurement id (and a fixed key for the hover preview). Mutated on the
    /// main thread but read from the render thread (updateScreenSizes), so all access
    /// goes through `nodesLock`.
    private var nodes: [UUID: MeasurementNodes] = [:]
    private let nodesLock = NSLock()
    private let hoverPreviewKey = UUID()

    /// Ids whose geometry changed since they were last sized. Lets the per-frame screen-size
    /// pass skip untouched measurements while the camera is still — otherwise it regenerates
    /// every line's cone mesh and dashed overlay on every frame.
    private var pendingResizeIDs: Set<UUID> = []
    private var lastSizedCameraTransform = SCNMatrix4Identity
    private var lastSizedCameraProjection = SCNMatrix4Identity
    private var lastHighlightedID: Measurement.ID?

    private var observers: Set<AnyCancellable> = []

    init(controller: MeasurementController, parentNode: SCNNode) {
        self.controller = controller
        self.parentNode = parentNode

        // Reconcile after each change settles (the sink runs on the next main-thread tick, so the
        // controller's published values are already updated when it reads them).
        controller.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.reconcile() }
            .store(in: &observers)

        reconcile() // build any measurements that already exist (e.g. on a split)
    }

    // MARK: - Reconciliation

    /// Brings this viewport's geometry in line with the controller's current measurements and hover
    /// preview: builds new or moved measurements, drops removed ones, and flags the highlight
    /// change for re-sizing.
    private func reconcile() {
        var desired: [(id: UUID, color: NSColor, start: SCNVector3, end: SCNVector3?)] = []
        for measurement in controller.measurements {
            desired.append((measurement.id, measurement.color, measurement.start, measurement.end))
        }
        if let preview = controller.hoverPreview {
            desired.append((hoverPreviewKey, preview.color, preview.start, preview.end))
        }
        let desiredIDs = Set(desired.map(\.id))

        nodesLock.lock()
        let existingIDs = Set(nodes.keys)
        nodesLock.unlock()

        for id in existingIDs.subtracting(desiredIDs) {
            removeNode(for: id)
        }

        for item in desired {
            nodesLock.lock()
            let existing = nodes[item.id]
            nodesLock.unlock()
            // A measurement's colour is fixed for its lifetime, so only the points can change.
            let changed = existing == nil
                || !samePoint(existing!.start, item.start)
                || !sameOptionalPoint(existing!.end, item.end)
            if changed {
                updateGeometry(id: item.id, color: item.color, start: item.start, end: item.end)
            }
        }

        if controller.highlightedID != lastHighlightedID {
            nodesLock.lock()
            if let old = lastHighlightedID { pendingResizeIDs.insert(old) }
            if let new = controller.highlightedID { pendingResizeIDs.insert(new) }
            nodesLock.unlock()
            lastHighlightedID = controller.highlightedID
        }

        onVisualChange?()
    }

    private func samePoint(_ a: SCNVector3, _ b: SCNVector3) -> Bool {
        a.x == b.x && a.y == b.y && a.z == b.z
    }

    private func sameOptionalPoint(_ a: SCNVector3?, _ b: SCNVector3?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (a?, b?): return samePoint(a, b)
        default: return false
        }
    }

    // MARK: - 3D geometry

    private func updateGeometry(id: UUID, color: NSColor, start: SCNVector3, end: SCNVector3?) {
        nodesLock.lock()
        let container = nodes[id]?.container ?? {
            let node = SCNNode()
            parentNode.addChildNode(node)
            return node
        }()
        nodesLock.unlock()

        container.childNodes.forEach { $0.removeFromParentNode() }

        var scalables: [SCNNode] = []
        let startDot = dotNode(at: start, color: color)
        container.addChildNode(startDot)
        scalables.append(startDot)

        var overlayLine: SCNNode?
        if let end {
            let endDot = dotNode(at: end, color: color)
            container.addChildNode(endDot)
            scalables.append(endDot)
            let line = lineNode(from: start, to: end, color: color)
            container.addChildNode(line)
            scalables.append(line)

            // Empty node; its dashed geometry is filled in per frame by updateScreenSizes.
            // Rendered before the solid line (lower order) so the opaque line paints over
            // it where the line is visible, leaving the dashes only where it's occluded.
            let overlay = SCNNode()
            overlay.renderingOrder = 1
            container.addChildNode(overlay)
            overlayLine = overlay
        }

        nodesLock.lock()
        pendingResizeIDs.insert(id)
        nodes[id] = MeasurementNodes(container: container, scalables: scalables, overlayLine: overlayLine, start: start, end: end, color: color)
        nodesLock.unlock()
    }

    private func dotNode(at position: SCNVector3, color: NSColor) -> SCNNode {
        let sphere = SCNSphere(radius: 1)
        configureMaterial(sphere.firstMaterial, color: color)
        let node = SCNNode(geometry: sphere)
        node.renderingOrder = 3 // on top of the line and dashed overlay
        node.position = position
        return node
    }

    private func configureMaterial(_ material: SCNMaterial?, color: NSColor) {
        material?.lightingModel = .constant
        // Just-barely transparent so the dots and line render in the transparent pass; that
        // lets renderingOrder place them after the dashed overlay, so the (opaque-looking)
        // line paints over the dashes where it's visible and they only show where occluded.
        // The 1% transparency is visually imperceptible.
        material?.diffuse.contents = color.withAlphaComponent(0.99)
        material?.writesToDepthBuffer = true
        material?.readsFromDepthBuffer = true
    }

    private func lineNode(from start: SCNVector3, to end: SCNVector3, color: NSColor) -> SCNNode {
        let length = end.distance(from: start)
        // A truncated cone (frustum) so each end can be sized independently, keeping a
        // constant on-screen thickness along the whole length even in perspective.
        let cone = SCNCone(topRadius: 1, bottomRadius: 1, height: CGFloat(length))
        cone.radialSegmentCount = 8
        configureMaterial(cone.firstMaterial, color: color)

        let node = SCNNode(geometry: cone)
        node.renderingOrder = 2 // over the dashed overlay so it hides the dashes where visible
        node.simdPosition = simd_float3(
            Float((start.x + end.x) / 2),
            Float((start.y + end.y) / 2),
            Float((start.z + end.z) / 2)
        )
        node.simdOrientation = orientation(from: start, to: end)
        return node
    }

    /// Rotation that maps the cone's default +Y axis onto the start→end direction.
    private func orientation(from start: SCNVector3, to end: SCNVector3) -> simd_quatf {
        let vector = simd_float3(Float(end.x - start.x), Float(end.y - start.y), Float(end.z - start.z))
        let length = simd_length(vector)
        let up = simd_float3(0, 1, 0)
        guard length > 1e-6 else { return simd_quatf(angle: 0, axis: up) }

        let direction = vector / length
        let axis = simd_cross(up, direction)
        let axisLength = simd_length(axis)
        // Only treat as a singularity when the rotation axis is genuinely undefined
        // (direction essentially parallel to ±Y); otherwise rotate by the real angle so
        // near-vertical lines keep their slight tilt instead of snapping to straight.
        guard axisLength > 1e-6 else {
            return simd_dot(up, direction) > 0 ? simd_quatf(angle: 0, axis: up) : simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0))
        }
        let angle = acos(max(-1, min(1, simd_dot(up, direction))))
        return simd_quatf(angle: angle, axis: axis / axisLength)
    }

    private func removeNode(for id: UUID) {
        nodesLock.lock()
        let entry = nodes.removeValue(forKey: id)
        pendingResizeIDs.remove(id)
        nodesLock.unlock()
        entry?.container.removeFromParentNode()
    }

    // MARK: - Constant on-screen sizing

    /// Rescales every dot and line so they keep a constant on-screen size regardless
    /// of zoom. Call once per rendered frame.
    func updateScreenSizes(renderer: SCNSceneRenderer) {
        guard let pointOfView = renderer.pointOfView else { return }
        let worldTransform = pointOfView.worldTransform
        let projection = pointOfView.camera?.projectionTransform ?? SCNMatrix4Identity

        nodesLock.lock()
        // Sizing depends on the camera (constant on-screen size) and on each measurement's
        // own geometry. If the camera moved, everything must be resized; otherwise only the
        // measurements that changed since last time.
        let cameraChanged = !SCNMatrix4EqualToMatrix4(worldTransform, lastSizedCameraTransform)
            || !SCNMatrix4EqualToMatrix4(projection, lastSizedCameraProjection)
        let ids = cameraChanged ? Array(nodes.keys) : Array(pendingResizeIDs)
        let entries = ids.compactMap { id in nodes[id].map { (id, $0) } }
        pendingResizeIDs.removeAll()
        lastSizedCameraTransform = worldTransform
        lastSizedCameraProjection = projection
        nodesLock.unlock()

        if entries.isEmpty { return }
        let highlighted = controller.highlightedID

        for (id, entry) in entries {
            let emphasis = (id == highlighted) ? 1.7 : 1.0
            let dotRadius = dotScreenRadius * emphasis
            let lineRadius = lineScreenRadius * emphasis

            for child in entry.scalables {
                // Scale via the node transform (not geometry radius) so changes apply in
                // the same frame without a deferred mesh rebuild.
                if child.geometry is SCNSphere {
                    let scale = Float(worldRadius(forScreenRadius: dotRadius, at: child.position, renderer: renderer))
                    child.simdScale = simd_float3(scale, scale, scale)
                } else if let cone = child.geometry as? SCNCone {
                    // The line's two ends are at ±height/2 along the node's local Y axis.
                    let direction = child.simdOrientation.act(simd_float3(0, 1, 0))
                    let half = Float(cone.height) / 2
                    let endRadius = worldRadius(forScreenRadius: lineRadius, at: SCNVector3(child.simdPosition + direction * half), renderer: renderer)
                    let startRadius = worldRadius(forScreenRadius: lineRadius, at: SCNVector3(child.simdPosition - direction * half), renderer: renderer)
                    let midRadius = worldRadius(forScreenRadius: lineRadius, at: child.position, renderer: renderer)
                    guard midRadius > 0 else { continue }

                    // Overall thickness comes from the node scale (a transform, applied this
                    // frame); the cone radii only carry the taper ratio between ends.
                    cone.topRadius = CGFloat(endRadius / midRadius)      // local +Y == end
                    cone.bottomRadius = CGFloat(startRadius / midRadius) // local -Y == start
                    child.simdScale = simd_float3(Float(midRadius), 1, Float(midRadius))
                }
            }

            if let overlayLine = entry.overlayLine, let end = entry.end {
                overlayLine.geometry = dashedOverlayGeometry(from: entry.start, to: end, color: entry.color, renderer: renderer)
            }
        }
    }

    /// Builds the subtle dashed line drawn on top of the model, with a constant on-screen
    /// dash size for the current camera.
    private func dashedOverlayGeometry(from start: SCNVector3, to end: SCNVector3, color: NSColor, renderer: SCNSceneRenderer) -> SCNGeometry {
        let projectedStart = renderer.projectPoint(start)
        let projectedEnd = renderer.projectPoint(end)
        let screenLength = hypot(projectedEnd.x - projectedStart.x, projectedEnd.y - projectedStart.y)

        let dashLength = 5.0   // view points
        let gapLength = 4.0
        let period = dashLength + gapLength

        var segments: [(SCNVector3, SCNVector3)] = []
        if screenLength > period {
            var distance = 0.0
            while distance < screenLength {
                let a = distance / screenLength
                let b = min((distance + dashLength) / screenLength, 1)
                segments.append((interpolate(start, end, a), interpolate(start, end, b)))
                distance += period
            }
        } else {
            segments = [(start, end)]
        }

        // Translucent and the same color as the line: drawn before the line (lower
        // renderingOrder) so the line paints over it where visible; only where the line is
        // occluded do the 0.5-opacity dashes show, blending with whatever's behind them so
        // they stay subtle over both light and dark geometry.
        let geometry = SCNGeometry.lines(segments, color: color.withAlphaComponent(0.5))
        geometry.firstMaterial?.readsFromDepthBuffer = false
        geometry.firstMaterial?.writesToDepthBuffer = false
        return geometry
    }

    private func interpolate(_ a: SCNVector3, _ b: SCNVector3, _ t: Double) -> SCNVector3 {
        SCNVector3(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t)
    }

    /// World-space radius at `worldPosition` that projects to `screenRadius` view points.
    private func worldRadius(forScreenRadius screenRadius: Double, at worldPosition: SCNVector3, renderer: SCNSceneRenderer) -> Double {
        let projected = renderer.projectPoint(worldPosition)
        let offset = renderer.unprojectPoint(SCNVector3(projected.x + CGFloat(screenRadius), projected.y, projected.z))
        let radius = offset.distance(from: worldPosition)
        return radius.isFinite ? max(radius, 0.0001) : 0.0001
    }
}

import Foundation
import SceneKit
import Combine
import AppKit
import simd
import ViewerCore

/// Owns the measurement state and the 3D geometry (dots + connecting lines) shown
/// for them. It is fed world-space points by the `ViewportController`; it performs
/// no hit testing itself.
final class MeasurementController: ObservableObject {
    @Published var interactionMode: InteractionMode = .view {
        didSet {
            guard interactionMode != oldValue else { return }
            if interactionMode != .measure {
                cancelInProgress()
            }
        }
    }

    /// Committed measurements, in creation order. The last one may be in progress.
    @Published private(set) var measurements: [Measurement] = []

    /// Transient measurement following the cursor before the first click. Not yet committed.
    @Published private(set) var hoverPreview: Measurement?

    private var nextColorIndex = 0

    private let parentNode: SCNNode
    private let categoryID: Int

    /// Desired on-screen radii (in view points), kept constant regardless of zoom.
    private let dotScreenRadius = 4.5
    private let lineScreenRadius = 1.6

    private struct MeasurementNodes {
        let container: SCNNode
        /// Dots and line that need per-frame on-screen-size scaling. Captured once when
        /// the geometry is (re)built, so the render thread never walks the live scene
        /// graph (`childNodes`) while the main thread mutates it.
        let scalables: [SCNNode]
    }

    /// Keyed by measurement id (and a fixed key for the hover preview). Mutated on the
    /// main thread but read from the render thread (updateScreenSizes), so all access
    /// goes through `nodesLock`.
    private var nodes: [UUID: MeasurementNodes] = [:]
    private let nodesLock = NSLock()
    private let hoverPreviewKey = UUID()

    init(parentNode: SCNNode, categoryID: Int) {
        self.parentNode = parentNode
        self.categoryID = categoryID
    }

    // MARK: - Interaction

    func hover(at worldPoint: SCNVector3?) {
        guard interactionMode == .measure else { return }

        if let index = inProgressIndex {
            measurements[index].end = worldPoint
            updateGeometry(for: measurements[index])
        } else if let worldPoint {
            if hoverPreview != nil {
                hoverPreview?.start = worldPoint
            } else {
                hoverPreview = Measurement(colorIndex: nextColorIndex, start: worldPoint, end: nil, phase: .coordinate)
            }
            updateHoverPreviewGeometry()
        } else {
            clearHoverPreview()
        }
    }

    func commitPoint(at worldPoint: SCNVector3) {
        guard interactionMode == .measure else { return }

        if let index = inProgressIndex {
            measurements[index].end = worldPoint
            measurements[index].phase = .complete
            updateGeometry(for: measurements[index])
        } else {
            clearHoverPreview()
            let measurement = Measurement(colorIndex: nextColorIndex, start: worldPoint, end: nil, phase: .lengthInProgress)
            nextColorIndex += 1
            measurements.append(measurement)
            updateGeometry(for: measurement)
        }
    }

    /// Cancels an in-progress length measurement (Escape, or leaving measure mode).
    func cancelInProgress() {
        clearHoverPreview()
        if let index = inProgressIndex {
            let removed = measurements.remove(at: index)
            removeNode(for: removed.id)
        }
    }

    func delete(_ id: Measurement.ID) {
        measurements.removeAll { $0.id == id }
        removeNode(for: id)
    }

    private var inProgressIndex: Int? {
        guard let last = measurements.indices.last, measurements[last].phase == .lengthInProgress else { return nil }
        return last
    }

    private func clearHoverPreview() {
        guard hoverPreview != nil else { return }
        hoverPreview = nil
        removeNode(for: hoverPreviewKey)
    }

    // MARK: - 3D geometry

    private func updateHoverPreviewGeometry() {
        if let hoverPreview {
            updateGeometry(id: hoverPreviewKey, color: hoverPreview.color, start: hoverPreview.start, end: nil)
        } else {
            removeNode(for: hoverPreviewKey)
        }
    }

    private func updateGeometry(for measurement: Measurement) {
        updateGeometry(id: measurement.id, color: measurement.color, start: measurement.start, end: measurement.end)
    }

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
        if let end {
            let endDot = dotNode(at: end, color: color)
            container.addChildNode(endDot)
            scalables.append(endDot)
            let line = lineNode(from: start, to: end, color: color)
            container.addChildNode(line)
            scalables.append(line)
        }

        container.setVisible(true, forViewportID: categoryID)

        nodesLock.lock()
        nodes[id] = MeasurementNodes(container: container, scalables: scalables)
        nodesLock.unlock()
    }

    private func dotNode(at position: SCNVector3, color: NSColor) -> SCNNode {
        let sphere = SCNSphere(radius: 1)
        configureMaterial(sphere.firstMaterial, color: color)
        let node = SCNNode(geometry: sphere)
        node.position = position
        return node
    }

    private func configureMaterial(_ material: SCNMaterial?, color: NSColor) {
        material?.lightingModel = .constant
        material?.diffuse.contents = color
    }

    private func lineNode(from start: SCNVector3, to end: SCNVector3, color: NSColor) -> SCNNode {
        let length = end.distance(from: start)
        // A truncated cone (frustum) so each end can be sized independently, keeping a
        // constant on-screen thickness along the whole length even in perspective.
        let cone = SCNCone(topRadius: 1, bottomRadius: 1, height: CGFloat(length))
        cone.radialSegmentCount = 8
        configureMaterial(cone.firstMaterial, color: color)

        let node = SCNNode(geometry: cone)
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
        nodesLock.unlock()
        entry?.container.removeFromParentNode()
    }

    // MARK: - Constant on-screen sizing

    /// Rescales every dot and line so they keep a constant on-screen size regardless
    /// of zoom. Call once per rendered frame.
    func updateScreenSizes(renderer: SCNSceneRenderer) {
        nodesLock.lock()
        let scalables = nodes.values.flatMap { $0.scalables }
        nodesLock.unlock()

        for child in scalables {
            // Scale via the node transform (not geometry radius) so changes apply in
            // the same frame without a deferred mesh rebuild.
            if child.geometry is SCNSphere {
                let scale = Float(worldRadius(forScreenRadius: dotScreenRadius, at: child.position, renderer: renderer))
                child.simdScale = simd_float3(scale, scale, scale)
            } else if let cone = child.geometry as? SCNCone {
                // The line's two ends are at ±height/2 along the node's local Y axis.
                let direction = child.simdOrientation.act(simd_float3(0, 1, 0))
                let half = Float(cone.height) / 2
                let endRadius = worldRadius(forScreenRadius: lineScreenRadius, at: SCNVector3(child.simdPosition + direction * half), renderer: renderer)
                let startRadius = worldRadius(forScreenRadius: lineScreenRadius, at: SCNVector3(child.simdPosition - direction * half), renderer: renderer)
                let midRadius = worldRadius(forScreenRadius: lineScreenRadius, at: child.position, renderer: renderer)
                guard midRadius > 0 else { continue }

                // Overall thickness comes from the node scale (a transform, applied this
                // frame); the cone radii only carry the taper ratio between ends.
                cone.topRadius = CGFloat(endRadius / midRadius)      // local +Y == end
                cone.bottomRadius = CGFloat(startRadius / midRadius) // local -Y == start
                child.simdScale = simd_float3(Float(midRadius), 1, Float(midRadius))
            }
        }
    }

    /// World-space radius at `worldPosition` that projects to `screenRadius` view points.
    private func worldRadius(forScreenRadius screenRadius: Double, at worldPosition: SCNVector3, renderer: SCNSceneRenderer) -> Double {
        let projected = renderer.projectPoint(worldPosition)
        let offset = renderer.unprojectPoint(SCNVector3(projected.x + CGFloat(screenRadius), projected.y, projected.z))
        let radius = offset.distance(from: worldPosition)
        return radius.isFinite ? max(radius, 0.0001) : 0.0001
    }
}

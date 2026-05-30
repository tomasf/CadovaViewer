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

    /// Desired on-screen radii (in view points) kept constant regardless of zoom.
    private let dotScreenRadius = 4.5
    private let lineScreenRadius = 1.0

    /// Container nodes keyed by measurement id (and a fixed key for the hover preview).
    private var nodes: [UUID: SCNNode] = [:]
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
        let container = nodes[id] ?? {
            let node = SCNNode()
            nodes[id] = node
            parentNode.addChildNode(node)
            return node
        }()
        container.childNodes.forEach { $0.removeFromParentNode() }

        container.addChildNode(dotNode(at: start, color: color))
        if let end {
            container.addChildNode(dotNode(at: end, color: color))
            container.addChildNode(lineNode(from: start, to: end, color: color))
        }

        container.setVisible(true, forViewportID: categoryID)
    }

    private func dotNode(at position: SCNVector3, color: NSColor) -> SCNNode {
        let sphere = SCNSphere(radius: 1)
        sphere.firstMaterial?.lightingModel = .constant
        sphere.firstMaterial?.diffuse.contents = color
        let node = SCNNode(geometry: sphere)
        node.position = position
        return node
    }

    private func lineNode(from start: SCNVector3, to end: SCNVector3, color: NSColor) -> SCNNode {
        let length = end.distance(from: start)
        let cylinder = SCNCylinder(radius: 1, height: CGFloat(length))
        cylinder.radialSegmentCount = 8
        cylinder.firstMaterial?.lightingModel = .constant
        cylinder.firstMaterial?.diffuse.contents = color

        let node = SCNNode(geometry: cylinder)
        node.simdPosition = simd_float3(
            Float((start.x + end.x) / 2),
            Float((start.y + end.y) / 2),
            Float((start.z + end.z) / 2)
        )
        node.simdOrientation = orientation(from: start, to: end)
        return node
    }

    /// Rotation that maps the cylinder's default +Y axis onto the start→end direction.
    private func orientation(from start: SCNVector3, to end: SCNVector3) -> simd_quatf {
        let vector = simd_float3(Float(end.x - start.x), Float(end.y - start.y), Float(end.z - start.z))
        let length = simd_length(vector)
        let up = simd_float3(0, 1, 0)
        guard length > 1e-6 else { return simd_quatf(angle: 0, axis: up) }

        let direction = vector / length
        let dot = simd_dot(up, direction)
        if dot > 0.9999 { return simd_quatf(angle: 0, axis: up) }
        if dot < -0.9999 { return simd_quatf(angle: .pi, axis: simd_float3(1, 0, 0)) }
        return simd_quatf(angle: acos(dot), axis: simd_normalize(simd_cross(up, direction)))
    }

    private func removeNode(for id: UUID) {
        nodes.removeValue(forKey: id)?.removeFromParentNode()
    }

    // MARK: - Constant on-screen sizing

    /// Rescales every dot and line so they keep a constant on-screen size regardless
    /// of zoom. Call once per rendered frame.
    func updateScreenSizes(renderer: SCNSceneRenderer) {
        for container in Array(nodes.values) {
            for child in container.childNodes {
                // Scale via the node transform (not geometry radius) so changes apply
                // in the same frame without a deferred mesh rebuild.
                if child.geometry is SCNSphere {
                    let scale = Float(worldRadius(forScreenRadius: dotScreenRadius, at: child.position, renderer: renderer))
                    child.simdScale = simd_float3(scale, scale, scale)
                } else if child.geometry is SCNCylinder {
                    // Scale only the cross-section (local X/Z); keep the length (local Y).
                    let scale = Float(worldRadius(forScreenRadius: lineScreenRadius, at: child.position, renderer: renderer))
                    child.simdScale = simd_float3(scale, 1, scale)
                }
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

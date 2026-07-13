import Foundation
import SceneKit
import ViewerCore

extension ViewportController {
    typealias CameraView = (transform: SCNMatrix4, orthographicScale: Double)

    enum MovementType {
        case instant
        case small
        case large
        case preview
    }

    func setCameraView(_ view: CameraView, movement: MovementType) {
        stopCameraInertia()
        setNavLibSuspended(true)

        SCNTransaction.begin()
        SCNTransaction.disableActions = movement == .instant || movement == .preview
        SCNTransaction.animationDuration = movement == .small ? 0.3 : 0.8

        SCNTransaction.completionBlock = {
            self.setNavLibSuspended(false)
        }

        cameraNode.transform = view.transform
        cameraNode.camera!.orthographicScale = view.orthographicScale
        SCNTransaction.commit()
        if movement != .preview {
            viewDidChange()
        }
    }

    var currentCameraView: CameraView {
        (cameraNode.transform, cameraNode.camera!.orthographicScale)
    }

    func canResetRoll() -> Bool {
        let forward = simd_normalize(cameraNode.simdWorldFront)
        let currentUp = simd_normalize(cameraNode.simdWorldUp)

        let upProjection = currentUp - simd_dot(currentUp, forward) * forward
        let projectedUp = simd_normalize(upProjection)

        let worldUp = SIMD3<Float>(0, 0, 1)
        let worldUpProjection = worldUp - simd_dot(worldUp, forward) * forward

        return abs(simd_dot(projectedUp, simd_normalize(worldUpProjection)) - 1) > 0.001
    }

    func clearRollView() -> CameraView {
        let forward = simd_normalize(cameraNode.presentation.simdWorldFront)
        let worldUp = simd_float3(self.worldUp)

        var right = simd_cross(forward, worldUp)
        if simd_length_squared(right) < 1.0e-6 {
            right = simd_float3(1, 0, 0)
        }
        right = simd_normalize(right)

        let transform = float4x4(columns: (
            simd_float4(right, 0),
            simd_float4(simd_normalize(simd_cross(right, forward)), 0),
            simd_float4(-forward, 0),
            simd_float4(cameraNode.simdWorldPosition, 1)
        ))

        return (SCNMatrix4(transform), cameraNode.camera!.orthographicScale)
    }

    func clearRoll() {
        setCameraView(clearRollView(), movement: .small)
    }

    func viewForZoom(amount: Double) -> CameraView {
        guard let pointOfView = sceneView.pointOfView, let camera = pointOfView.camera else { fatalError() }

        let point = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        let target: SCNVector3
        if let match = nearestVisibleHit(at: point, in: modelInstance.root) {
            target = match.worldCoordinates
        } else {
            target = sceneView.xyPlanePoint(forViewPoint: point)
        }

        let distance = target.distance(from: pointOfView.worldPosition)
        let distanceFactor = amount > 0 ? amount : amount / (1.0 + amount)
        let transform = SCNMatrix4Mult(SCNMatrix4MakeTranslation(0, 0, -CGFloat(distance * distanceFactor)), cameraNode.presentation.transform)

        var amount = amount * 5
        if amount < 0 { amount = 1 / -amount }
        let newOrthoScale = camera.orthographicScale / Double(amount)

        return (transform, newOrthoScale)
    }

    func zoomIn() {
        setCameraView(viewForZoom(amount: 0.3), movement: .small)
    }

    func zoomOut() {
        setCameraView(viewForZoom(amount: -0.3), movement: .small)
    }

    func canShowView(_ view: CameraView) -> Bool {
        fabs(view.orthographicScale - cameraNode.camera!.orthographicScale) > 0.001 || !cameraNode.simdWorldTransform.functionallyEqual(to: .init(view.transform))
    }

}

extension ViewportController {

    func showViewPreset(_ preset: ViewPreset, animated: Bool) {
        setCameraView(cameraView(for: preset), movement: animated ? .large : .instant)
    }

    func canShowViewPreset(_ preset: ViewPreset) -> Bool {
        canShowView(cameraView(for: preset))
    }

    func cameraView(for preset: ViewPreset) -> CameraView {
        var (min, max) = sceneController.modelBoundingBox
        var sphere = sceneController.modelBoundingSphere

        if min == max {
            (min, max) = modelInstance.root.boundingBox
        }
        if sphere.radius <= 0 || !sphere.radius.isFinite {
            sphere = modelInstance.root.boundingSphere
        }

        let center = SIMD3<Double>(sphere.center)
        return cameraView(axis: preset.axis,
                          boundingBox: (SIMD3<Double>(min), SIMD3<Double>(max)),
                          center: center)
    }

    /// Frames a world-space bounding box from the given outward `axis`, looking at `center`, with
    /// the same margin the standard presets use. Shared by the preset views and by centering on a
    /// subset of parts.
    func cameraView(axis: SIMD3<Double>, boundingBox: (min: SIMD3<Double>, max: SIMD3<Double>), center: SIMD3<Double>) -> CameraView {
        guard let camera = cameraNode.camera else {
            return (cameraNode.transform, 1)
        }

        // The scene view spans the whole detail area, but part of it is hidden under the floating
        // sidebar (and the title bar). Fit and centre the model in the *visible* sub-rectangle so it
        // isn't undersized or shoved under the sidebar. `safeAreaInsets` reports exactly how much of
        // each edge is obscured.
        let storedSize = sceneViewSize
        let boundsSize = sceneView.bounds.size
        let full = CGSize(
            width: storedSize.width > 0 ? storedSize.width : Swift.max(boundsSize.width, 1),
            height: storedSize.height > 0 ? storedSize.height : Swift.max(boundsSize.height, 1)
        )
        let insets = sceneView.safeAreaInsets
        let visibleWidth = Swift.max(full.width - insets.left - insets.right, 1)
        let visibleHeight = Swift.max(full.height - insets.top - insets.bottom, 1)

        // Frame against the *visible* rectangle's aspect ratio, so the margin/fit math accounts for
        // the sidebar the same way the pan-to-centre step below does.
        let framing = frameBoundingBox(
            axis: axis,
            boundingBox: boundingBox,
            center: center,
            fieldOfViewDegrees: Double(camera.fieldOfView),
            aspectRatio: Double(visibleWidth / visibleHeight)
        )

        // Pan the camera so the model centre lands at the centre of the visible rectangle rather than
        // the full view. The visible centre is offset from the full centre by half the difference of
        // opposing insets; shifting the camera the opposite way moves the model the matching amount on
        // screen. (AppKit y grows upward, matching `up`; x grows right, matching `right`.)
        let worldPerPoint = full.height > 0 ? 2 * framing.orthographicScale / full.height : 0
        let offsetRight = (insets.left - insets.right) / 2 * worldPerPoint
        let offsetUp = (insets.bottom - insets.top) / 2 * worldPerPoint
        let shift = framing.right * -offsetRight + framing.up * -offsetUp
        let shiftedCenter = center + shift
        let position = shiftedCenter + axis * framing.distance

        return (SCNMatrix4(float4x4(lookingFrom: SIMD3<Float>(position), at: SIMD3<Float>(shiftedCenter))), framing.orthographicScale)
    }

    /// Animates the camera to an isometric framing of the given parts (their combined world-space
    /// bounding box). No-op if none of the ids resolve to a part node with measurable bounds.
    func centerView(onPartIDs ids: Set<ModelData.Part.ID>) {
        guard let box = combinedWorldBoundingBox(ofPartIDs: ids) else { return }
        let center = (box.min + box.max) / 2
        setCameraView(cameraView(axis: ViewPreset.isometric.axis, boundingBox: box, center: center), movement: .large)
    }

    /// The union, in world space, of the bounding boxes of the given parts' clone container nodes in
    /// this viewport's scene. Returns nil if no node resolves or the result has no extent.
    private func combinedWorldBoundingBox(ofPartIDs ids: Set<ModelData.Part.ID>) -> (min: SIMD3<Double>, max: SIMD3<Double>)? {
        var result: (min: SIMD3<Double>, max: SIMD3<Double>)?
        for id in ids {
            guard let node = modelInstance.partContainers[id] else { continue }
            let (localMin, localMax) = node.boundingBox
            let transform = node.simdWorldTransform
            let corners: [SIMD3<Float>] = [
                SIMD3(Float(localMin.x), Float(localMin.y), Float(localMin.z)),
                SIMD3(Float(localMin.x), Float(localMin.y), Float(localMax.z)),
                SIMD3(Float(localMin.x), Float(localMax.y), Float(localMin.z)),
                SIMD3(Float(localMin.x), Float(localMax.y), Float(localMax.z)),
                SIMD3(Float(localMax.x), Float(localMin.y), Float(localMin.z)),
                SIMD3(Float(localMax.x), Float(localMin.y), Float(localMax.z)),
                SIMD3(Float(localMax.x), Float(localMax.y), Float(localMin.z)),
                SIMD3(Float(localMax.x), Float(localMax.y), Float(localMax.z))
            ]
            for corner in corners {
                let world = SIMD3<Double>((transform * SIMD4<Float>(corner, 1)).xyz)
                if result == nil {
                    result = (world, world)
                } else {
                    result!.min = simd_min(result!.min, world)
                    result!.max = simd_max(result!.max, world)
                }
            }
        }
        guard let box = result, box.max.x > box.min.x || box.max.y > box.min.y || box.max.z > box.min.z else { return nil }
        return box
    }
}

extension simd_float4x4 {
    func functionallyEqual(to other: simd_float4x4) -> Bool {
        let tolerance: Float = 0.001

        if simd_distance(self[3].xyz, other[3].xyz) > tolerance {
            return false
        }

        let dot = abs(simd_dot(simd_quaternion(self).vector, simd_quaternion(other).vector))
        return dot > 1 - tolerance
    }
}

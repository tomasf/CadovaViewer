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
        let worldUp = simd_float3(sceneView.defaultCameraController.worldUp)

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

    func viewForZoom(amount: Double) -> CameraView {
        guard let pointOfView = sceneView.pointOfView, let camera = pointOfView.camera else { fatalError() }

        let point = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
        let target: SCNVector3
        if let match = sceneView.hitTest(point, options: [.rootNode: modelInstance.root, .searchMode: NSNumber(value: SCNHitTestSearchMode.any.rawValue)]).first {
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
        let (min, max) = sceneController.modelBoundingBox
        let center = SIMD3<Double>(sceneController.modelBoundingSphere.center)
        return cameraView(axis: Self.viewAxis(for: preset),
                          boundingBox: (SIMD3<Double>(min), SIMD3<Double>(max)),
                          center: center)
    }

    /// The outward view axis (a unit vector pointing from the model center toward the camera) for
    /// each standard preset.
    static func viewAxis(for preset: ViewPreset) -> SIMD3<Double> {
        switch preset {
        case .isometric:
            let isoAngle = 35.264 * (.pi / 180)
            return simd_normalize(SIMD3(-cos(isoAngle), -cos(isoAngle), sin(isoAngle)))
        case .front:  return SIMD3(0, -1, 0)
        case .back:   return SIMD3(0,  1, 0)
        case .left:   return SIMD3(-1, 0, 0)
        case .right:  return SIMD3( 1, 0, 0)
        case .top:    return SIMD3(0, 0,  1)
        case .bottom: return SIMD3(0, 0, -1)
        }
    }

    /// Frames a world-space bounding box from the given outward `axis`, looking at `center`, with
    /// the same margin the standard presets use. Shared by the preset views and by centering on a
    /// subset of parts.
    func cameraView(axis: SIMD3<Double>, boundingBox: (min: SIMD3<Double>, max: SIMD3<Double>), center: SIMD3<Double>) -> CameraView {
        guard let cameraNode = sceneView.pointOfView,
              let camera = cameraNode.camera else { return (CATransform3DIdentity, 1) }

        let (min, max) = boundingBox

        // Build a provisional orientation (distance-independent) so we know the camera's
        // right/up vectors, then project the 8 bbox corners onto them to get the true
        // on-screen extents. This handles every preset uniformly and works even when the
        // model isn't centered on its bounding sphere. The lookingFrom helper supplies a
        // sane right/up fallback for the top/bottom cases where the view axis is parallel
        // to world up.
        let orientation = float4x4(lookingFrom: SIMD3<Float>(center + axis), at: SIMD3<Float>(center))
        let right = SIMD3<Double>(orientation.columns.0.xyz)
        let up = SIMD3<Double>(orientation.columns.1.xyz)

        let corners: [SIMD3<Double>] = [
            SIMD3(min.x, min.y, min.z), SIMD3(min.x, min.y, max.z),
            SIMD3(min.x, max.y, min.z), SIMD3(min.x, max.y, max.z),
            SIMD3(max.x, min.y, min.z), SIMD3(max.x, min.y, max.z),
            SIMD3(max.x, max.y, min.z), SIMD3(max.x, max.y, max.z)
        ]

        var minU = Double.greatestFiniteMagnitude, maxU = -Double.greatestFiniteMagnitude
        var minV = Double.greatestFiniteMagnitude, maxV = -Double.greatestFiniteMagnitude
        for corner in corners {
            let diff = corner - center
            let u = simd_dot(diff, right)
            let v = simd_dot(diff, up)
            minU = Swift.min(minU, u); maxU = Swift.max(maxU, u)
            minV = Swift.min(minV, v); maxV = Swift.max(maxV, v)
        }

        let width = maxU - minU
        let height = maxV - minV

        let aspect = sceneViewSize.height > 0 ? sceneViewSize.width / sceneViewSize.height : 1
        let fitWidthScale = width / 2 / aspect
        let fitHeightScale = height / 2
        let orthoScale = Swift.max(fitWidthScale, fitHeightScale) * 1.5

        // Place the camera at the distance that makes calculateOrthographicScale()
        // (distance * tan(fov/2), the value SceneKit actually uses for the ortho
        // projection) reproduce exactly orthoScale, so the framing isn't overridden.
        // The same distance frames the model with matching margin in perspective mode.
        let fovRadians = camera.fieldOfView * (.pi / 180.0)
        let distance = orthoScale / tan(fovRadians / 2)
        let position = center + axis * distance

        return (SCNMatrix4(float4x4(lookingFrom: SIMD3<Float>(position), at: SIMD3<Float>(center))), orthoScale)
    }

    /// Animates the camera to an isometric framing of the given parts (their combined world-space
    /// bounding box). No-op if none of the ids resolve to a part node with measurable bounds.
    func centerView(onPartIDs ids: Set<ModelData.Part.ID>) {
        guard let box = combinedWorldBoundingBox(ofPartIDs: ids) else { return }
        let center = (box.min + box.max) / 2
        setCameraView(cameraView(axis: Self.viewAxis(for: .isometric), boundingBox: box, center: center), movement: .large)
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

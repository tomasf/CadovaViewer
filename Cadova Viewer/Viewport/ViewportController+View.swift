import Foundation
import SceneKit

extension ViewportController {
    typealias CameraView = (transform: SCNMatrix4, orthographicScale: Double)

    func canShowViewPreset(_ preset: ViewPreset) -> Bool {
        canShowView(cameraView(for: preset))
    }

    func cameraView(for preset: ViewPreset) -> CameraView {
        guard let cameraNode = sceneView.pointOfView,
              let camera = cameraNode.camera else { return (CATransform3DIdentity, 1) }

        let (min, max) = sceneController.modelContainer.boundingBox
        let center = sceneController.modelContainer.boundingSphere.center
        let modelSize = SCNVector3(
            x: max.x - min.x,
            y: max.y - min.y,
            z: max.z - min.z
        )

        let objectSizeX = Swift.max(modelSize.y, modelSize.z)
        let objectSizeY = Swift.max(modelSize.x, modelSize.z)
        let objectSizeZ = Swift.max(modelSize.x, modelSize.y)

        let fovRadians = camera.fieldOfView * (.pi / 180.0)
        let distanceX = (objectSizeX / 2) / tan(fovRadians / 2)
        let distanceY = (objectSizeY / 2) / tan(fovRadians / 2)
        let distanceZ = (objectSizeZ / 2) / tan(fovRadians / 2)


        var position: SCNVector3 = center
        var width = modelSize.x
        var height = modelSize.z

        switch preset {
        case .isometric:
            let isoAngle = 35.264 * (.pi / 180)
            let isoDist  = Swift.max(distanceX, distanceY, distanceZ)

            position = SCNVector3(
                x: center.x - isoDist * cos(isoAngle),
                y: center.y - isoDist * cos(isoAngle),
                z: center.z + isoDist * sin(isoAngle)
            )

            // 2. Build the transform once so we know right / up vectors
            let isoTransform = makeCameraTransform(
                position: .init(position),
                target:   .init(center)
            )
            let right = isoTransform.columns.0.xyz   // camera-space +X in world
            let up = isoTransform.columns.1.xyz   // camera-space +Y in world

            // 3. Project the 8 bbox corners onto (right, up)
            let corners: [SIMD3<Double>] = [
                SIMD3(min.x, min.y, min.z), SIMD3(min.x, min.y, max.z),
                SIMD3(min.x, max.y, min.z), SIMD3(min.x, max.y, max.z),
                SIMD3(max.x, min.y, min.z), SIMD3(max.x, min.y, max.z),
                SIMD3(max.x, max.y, min.z), SIMD3(max.x, max.y, max.z)
            ]

            var minU: Double = .greatestFiniteMagnitude, maxU: Double = -.greatestFiniteMagnitude
            var minV: Double = .greatestFiniteMagnitude, maxV: Double = -.greatestFiniteMagnitude

            let camPos = SIMD3<Double>(position)
            for c in corners {
                let diff = c - camPos
                let u = simd_dot(diff, SIMD3<Double>(right))   // horizontal
                let v = simd_dot(diff, SIMD3<Double>(up))      // vertical
                minU = Swift.min(minU, u)
                maxU = Swift.max(maxU, u)
                minV = Swift.min(minV, v)
                maxV = Swift.max(maxV, v)
            }

            width  = maxU - minU
            height = maxV - minV

        case .front:
            position.y = min.y - distanceY
        case .back:
            position.y = max.y + distanceY
        case .left:
            position.x = min.x - distanceX
            width = modelSize.y
        case .right:
            position.x = max.x + distanceX
            width = modelSize.y
        case .top:
            position.z = max.z + distanceZ
            height = modelSize.y
        case .bottom:
            position.z = min.z - distanceZ
            position.x += 0.001 // uh ok. why
            height = modelSize.y
        }

        let fitWidthScale = width / 2 / (sceneViewSize.width / sceneViewSize.height)
        let fitHeightScale = height / 2
        let orthoScale = Swift.max(fitWidthScale, fitHeightScale) * 1.5

        return (SCNMatrix4(makeCameraTransform(position: .init(position), target: .init(center))), orthoScale)
    }

    func makeCameraTransform(position: simd_float3, target: simd_float3) -> float4x4 {
        let worldUp = simd_float3(0, 0, 1)
        var forward = target - position
        if simd_length_squared(forward) < 1.0e-12 {
            return matrix_identity_float4x4
        }
        forward = simd_normalize(forward)

        var right = simd_cross(forward, worldUp)
        if simd_length_squared(right) < 1.0e-6 {
            right = simd_dot(forward, worldUp) > 0
            ? simd_float3(-1, 0, 0) // X points left for bottom view
            : simd_float3( 1, 0, 0) // X points right for top view
        }
        right = simd_normalize(right)

        return float4x4(columns: (
            simd_float4(right, 0),
            simd_float4(simd_normalize(simd_cross(right, forward)), 0),
            simd_float4(-forward,    0),
            simd_float4(position, 1)
        ))
    }

    enum MovementType {
        case instant
        case small
        case large
    }

    func setCameraView(_ view: CameraView, movement: MovementType) {
        setNavLibSuspended(true)
        isAnimatingView = true

        SCNTransaction.begin()
        SCNTransaction.disableActions = movement == .instant
        SCNTransaction.animationDuration = movement == .small ? 0.3 : 0.8

        SCNTransaction.completionBlock = {
            self.setNavLibSuspended(false)
            self.isAnimatingView = false
        }

        cameraNode.transform = view.transform
        cameraNode.camera!.orthographicScale = view.orthographicScale
        SCNTransaction.commit()
        viewDidChange()
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
        if let match = sceneView.hitTest(point, options: [.rootNode: sceneController.modelContainer, .searchMode: NSNumber(value: SCNHitTestSearchMode.any.rawValue)]).first {
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

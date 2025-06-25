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
            //position = SCNVector3(min.x - distanceX, min.y - distanceY, max.z + distanceZ)
            let isometricAngle = 35.264 * (.pi / 180)
            let isometricDistance = Swift.max(distanceX, distanceY, distanceZ)

            // Position the camera for isometric view
            position = SCNVector3(
                x: center.x - isometricDistance * cos(isometricAngle),
                y: center.y - isometricDistance * cos(isometricAngle),
                z: center.z + isometricDistance * sin(isometricAngle)
            )
            width = sqrt(distanceX * distanceX + distanceY * distanceY + distanceZ * distanceZ) * 0.70
            height = width
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

        return captureView {
            cameraNode.position = position
            cameraNode.look(at: center, up: SCNVector3(0, 0, 1), localFront: SCNNode.localFront)
            if preset == .top || preset == .bottom {
                cameraNode.eulerAngles.z = 0
            }
            camera.orthographicScale = orthoScale
        }
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
    }

    func captureView(for actions: () -> ()) -> CameraView {
        let savedTransform = cameraNode.transform
        let savedScale = cameraNode.camera!.orthographicScale
        actions()
        let t = cameraNode.transform
        let s = cameraNode.camera!.orthographicScale
        cameraNode.transform = savedTransform
        cameraNode.camera!.orthographicScale = savedScale
        return (t, s)
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
        let transform = cameraNode.simdWorldTransform

        let forward = simd_normalize(-cameraNode.simdWorldFront)
        let worldUp = SIMD3<Float>(0, 0, 1)
        let right = simd_normalize(simd_cross(worldUp, forward))
        let correctedUp = simd_normalize(simd_cross(forward, right))

        let newTransform = simd_float4x4(.init(right, 0), .init(correctedUp, 0), .init(forward, 0), transform[3])

        return (SCNMatrix4(newTransform), cameraNode.camera!.orthographicScale)
    }

    func viewForZoom(amount: Double) -> CameraView {
        captureView {
            guard let pointOfView = sceneView.pointOfView, let camera = pointOfView.camera else { return }

            if camera.usesOrthographicProjection {
                var amount = amount * 5
                if amount < 0 { amount = 1 / -amount }
                camera.orthographicScale /= Double(amount)

            } else {
                let point = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
                let target: SCNVector3
                if let match = sceneView.hitTest(point, options: [.rootNode: sceneController.modelContainer, .searchMode: NSNumber(value: SCNHitTestSearchMode.any.rawValue)]).first {
                    target = match.worldCoordinates
                } else {
                    target = sceneView.xyPlanePoint(forViewPoint: point)
                }

                let distance = target.distance(from: pointOfView.worldPosition)
                let distanceFactor = amount > 0 ? amount : amount / (1.0 + amount)

                sceneView.defaultCameraController.translateInCameraSpaceBy(x: 0, y: 0, z: -Float(distance * distanceFactor))
            }
        }
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

import Foundation
import SceneKit

extension SceneController {
    typealias CameraView = (transform: SCNMatrix4, orthographicScale: Double)

    func cameraView(for preset: ViewPreset) -> CameraView {
        guard let cameraNode = sceneView.pointOfView,
              let camera = cameraNode.camera else { return (CATransform3DIdentity, 1) }

        //updateCamera()

        let (min, max) = modelContainer.boundingBox
        let center = modelContainer.boundingSphere.center
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
                x: center.x + isometricDistance * cos(isometricAngle),
                y: center.y + isometricDistance * cos(isometricAngle),
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

        let fitWidthScale = width / 2 / (sceneViewBounds.width / sceneViewBounds.height)
        let fitHeightScale = height / 2
        let orthoScale = Swift.max(fitWidthScale, fitHeightScale) * 1.5

        return cameraView {
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

        SCNTransaction.begin()
        SCNTransaction.disableActions = movement == .instant
        SCNTransaction.animationDuration = movement == .small ? 0.3 : 0.8

        SCNTransaction.completionBlock = {
            self.setNavLibSuspended(false)
        }

        cameraNode.transform = view.transform
        cameraNode.camera!.orthographicScale = view.orthographicScale
        SCNTransaction.commit()
    }

    func cameraView(for actions: () -> ()) -> CameraView {
        let savedTransform = cameraNode.transform
        let savedScale = cameraNode.camera!.orthographicScale
        actions()
        let t = cameraNode.transform
        let s = cameraNode.camera!.orthographicScale
        cameraNode.transform = savedTransform
        cameraNode.camera!.orthographicScale = savedScale
        return (t, s)
    }

    func clearRollView() -> CameraView {
        cameraView {
            sceneView.defaultCameraController.clearRoll()
        }
    }

    func viewForZoom(amount: Double) -> CameraView {
        cameraView {
            guard let pointOfView = sceneView.pointOfView, let camera = pointOfView.camera else { return }

            if camera.usesOrthographicProjection {
                var amount = amount * 0.5
                if amount < 0 { amount = 1 / -amount }
                camera.orthographicScale /= amount
            } else {
                let point = CGPoint(x: sceneView.bounds.midX, y: sceneView.bounds.midY)
                let target: SCNVector3
                if let match = sceneView.hitTest(point, options: [.rootNode: modelContainer, .searchMode: NSNumber(value: SCNHitTestSearchMode.any.rawValue)]).first {
                    target = match.worldCoordinates
                } else {
                    target = sceneView.xyPlanePoint(forViewPoint: point)
                }

                let distance = target.distance(from: pointOfView.worldPosition)
                let factor = 0.1

                sceneView.defaultCameraController.translateInCameraSpaceBy(x: 0, y: 0, z: -Float(distance * factor * amount))
            }

        }
    }
}

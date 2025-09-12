import Foundation
import Combine
import SceneKit
import NavLib

extension ViewportController {
    func startNavLib() {
        do {
            try navLibSession.start(stateProvider: self, applicationName: "Model Viewer")
            navLibIsActive = true
        } catch {
            print("NavLib initialization failed: \(error)")
        }

        NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateNavLibFocus()
            }.store(in: &observers)

        NSWorkspace.shared.publisher(for: \.frontmostApplication).sink { [weak self] runningApp in
            guard let self else { return }
            guard let runningApp, navLibIsActive else { return }

            //print("Frontmost: \(runningApp.bundleIdentifier ?? "nil bundle id")")

            if runningApp.bundleIdentifier == Bundle.main.bundleIdentifier {
                navLibSession.applicationHasFocus = true
                return
            }

            let active = switch Preferences().navLibActivationBehavior {
            case .always: true
            case .foregroundOnly: runningApp.bundleIdentifier == Bundle.main.bundleIdentifier
            case .specificApplicationsInForeground: Preferences().navLibWhitelistedApps.map(\.bundleIdentifier).contains(runningApp.bundleIdentifier)
            }

            //print("navlib active \(active), for \(Preferences().navLibActivationBehavior)")
            navLibSession.applicationHasFocus = active
        }.store(in: &observers)
    }

    func updateNavLibFocus() {
        if let main = NSApp.mainWindow, NSDocumentController.shared.document(for: main) == document {
            navLibSession.setAsActiveSession()
            navLibIsActive = true
        } else {
            navLibIsActive = false
        }
    }

    func updateNavLibPointerPosition() {
        guard let position = mousePosition else { return }
        navLibSession.mousePosition = position
    }

    func updateNavLibProjection() {
        guard let cameraProjection else { return }
        navLibSession.cameraProjection = cameraProjection
    }

    func setNavLibSuspended(_ suspend: Bool) {
        navLibIsSuspended = suspend
        navLibSession.cancelMotion()
    }
}

extension ViewportController: NavLibStateProvider {
    var modelBoundingBox: SCNVector3.BoundingBox {
        sceneController.modelContainer.boundingBox
    }
    
    var cameraTransform: NavLib.Transform {
        get {
            (sceneView.pointOfView?.presentation.transform ?? SCNMatrix4Identity).navLibTransform
        }
        set {
            guard let pov = sceneView.pointOfView, !navLibIsSuspended else { return }
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            pov.transform = newValue.scnMatrix
            SCNTransaction.commit()
        }
    }

    var unitsInMeters: Double? { 0.001 }
    var hasEmptySelection: Bool? { true }

    var cameraProjection: NavLib.CameraProjection<SCNVector3>? {
        get {
            guard let camera = sceneView.pointOfView?.camera else { return nil }

            if camera.usesOrthographicProjection {
                let aspectRatio = sceneView.bounds.width / sceneView.bounds.height
                return .orthographic (viewExtents: camera.orthographicViewExtents(viewAspectRatio: aspectRatio))
            } else {
                return .perspective (fov: camera.fieldOfView)
            }
        }
        set {
            guard !navLibIsSuspended, let camera = sceneView.pointOfView?.camera, case .orthographic(let extents) = newValue else { return }
            camera.orthographicScale = 0.5 * (Double(extents.max.y) - Double(extents.min.y))
        }
    }

    var frontView: Transform? {
        cameraView(for: .front).transform.navLibTransform
    }

    func pivotChanged(position: SCNVector3, visible: Bool) {
        guard !navLibIsSuspended else { return }
        overlayScene.pivotPointVisibility = visible
        overlayScene.pivotPointLocation = position.scnVector
    }

    func hitTest(parameters: HitTest<SCNVector3>) -> SCNVector3? {
        let origin = parameters.origin.scnVector
        let direction = parameters.direction.scnVector

        let length = 100000.0
        let end = SCNVector3(
            x: origin.x + direction.x * length,
            y: origin.y + direction.y * length,
            z: origin.z + direction.z * length
        )
        
        let edgeNodes = sceneController.edgeNodes
        guard let result = sceneController.modelContainer
            .hitTestWithSegment(from: origin, to: end)
            .first(where: { !edgeNodes.contains($0.node) })
        else {
            return nil
        }

        //print("Hit: \(result.worldCoordinates) \(result.node)")
        //sceneView.scene?.rootNode.addChildNode(debugSphere)
        //debugSphere.geometry?.firstMaterial?.diffuse.contents = NSColor.green
        //debugSphere.position = result.worldCoordinates

        return result.worldCoordinates
    }

    var mousePosition: SCNVector3? {
        guard var hoverPoint = hoverPoint else { return nil }
        hoverPoint.y = sceneViewSize.height - hoverPoint.y
        return sceneView.unprojectPoint(SCNVector3(hoverPoint.x, hoverPoint.y, 0))
    }

    func motionActiveChanged(_ active: Bool) {
        guard !navLibIsSuspended else { return }
        if active {
            sceneView.defaultCameraController.stopInertia()
        } else {
            viewDidChange()
        }
        sceneView.allowsCameraControl = !active
    }
}

fileprivate extension SCNCamera {
    func orthographicViewExtents(viewAspectRatio: Double) -> SCNVector3.BoundingBox {
        let height = orthographicScale * 2
        let width = height * viewAspectRatio
        return (
            min: SCNVector3(-width / 2, -height / 2, zNear),
            max: SCNVector3(width / 2, height / 2, zFar)
        )
    }
}

extension SCNVector3: NavLib.Vector {
    public init(x: Double, y: Double, z: Double) {
        self.init(x, y, z)
    }
}

extension Transform {
    var scnMatrix: SCNMatrix4 {
        SCNMatrix4(
            m11: values[0],  m12: values[1],  m13: values[2],  m14: values[3],
            m21: values[4],  m22: values[5],  m23: values[6],  m24: values[7],
            m31: values[8],  m32: values[9],  m33: values[10], m34: values[11],
            m41: values[12], m42: values[13], m43: values[14], m44: values[15]
        )
    }
}

extension Vector {
    var scnVector: SCNVector3 {
        .init(Double(x), Double(y), Double(z))
    }
}

extension SCNMatrix4 {
    public var navLibTransform: NavLib.Transform {
        .init([m11, m12, m13, m14,  m21, m22, m23, m24,  m31, m32, m33, m34,  m41, m42, m43, m44])
    }
}

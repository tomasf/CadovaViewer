import Foundation
import SceneKit
import NavLibSwift
import NavLib

extension navlib.matrix_t {
    init(scnMatrix m: SCNMatrix4) {
        self = .init(m00: m.m11, m01: m.m12, m02: m.m13, m03: m.m14,
                     m10: m.m21, m11: m.m22, m12: m.m23, m13: m.m24,
                     m20: m.m31, m21: m.m32, m22: m.m33, m23: m.m34,
                     m30: m.m41, m31: m.m42, m32: m.m43, m33: m.m44)
    }

    var scnMatrix: SCNMatrix4 {
        SCNMatrix4(m11: m00, m12: m01, m13: m02, m14: m03,
                   m21: m10, m22: m11, m23: m12, m24: m13,
                   m31: m20, m32: m21, m33: m22, m34: m23,
                   m41: m30, m42: m31, m43: m32, m44: m33)
    }
}

extension navlib.point_t {
    init(_ v: SCNVector3) {
        self.init(x: v.x, y: v.y, z: v.z)
    }

    var scnVector: SCNVector3 {
        .init(x: x, y: y, z: z)
    }
}

extension navlib.vector_t {
    init(_ v: SCNVector3) {
        self.init(x: v.x, y: v.y, z: v.z)
    }

    var scnVector: SCNVector3 {
        .init(x: x, y: y, z: z)
    }
}

extension navlib.box_t {
    init(min: SCNVector3, max: SCNVector3) {
        self.init(min: .init(min), max: .init(max))
    }
}

extension SceneController {
    func startNavLib() {
        session[getter: .unitsToMeters] = { 0.001 }

        session[getter: .modelExtents] = { [weak self] in
            guard let modelContainer = self?.modelContainer else { return .init() }
            let bounds = modelContainer.boundingBox
            return .init(min: bounds.min, max: bounds.max)
        }

        session[getter: .cameraTransform] = { [weak self] in
            guard let sceneView = self?.sceneView else { return .init() }
            guard let transform = sceneView.pointOfView?.presentation.transform else { return .init() }

            return .init(scnMatrix: transform)
        }

        session[setter: .cameraTransform] = { [weak self] transform in
            guard let self, let pov = sceneView.pointOfView, !navLibIsSuspended else { return }
            SCNTransaction.disableActions = true
            pov.transform = transform.scnMatrix
        }

        session[getter: .viewFOV] = { [weak self] in
            guard let camera = self?.sceneView.pointOfView?.camera else { return 0 }
            print("FOV: \(camera.fieldOfView) deg = \(camera.fieldOfView / 180.0 * Double.pi)")
            return camera.fieldOfView / 180.0 * Double.pi
        }

        session[getter: .viewIsPerspective] = { [weak self] in
            guard let camera = self?.sceneView.pointOfView?.camera else { return nil }
            return !camera.usesOrthographicProjection
        }

        session[getter: .orthographicViewExtents] = { [weak self] in
            self?.orthographicViewExtents
        }

        session[setter: .orthographicViewExtents] = { [weak self] extents in
            guard let self, let camera = sceneView.pointOfView?.camera, !navLibIsSuspended else { return }
            camera.orthographicScale = 0.5 * (extents.max.y - extents.min.y)
        }

        session[getter: .frontView] = { [weak self] in
            let front = self?.cameraView(for: .front).transform ?? CATransform3DIdentity
            return .init(scnMatrix: front)
        }

        session[setter: .pivotPosition] = { [weak self] in
            self?.pivotPoint = $0.scnVector
        }

        session[setter: .pivotIsVisible] = { [weak self] in
            self?.showPivotMarker = $0
        }

        session[getter: .pointerPosition] = { [weak self] in
            return self?.navLibPointerPosition.map { .init($0) }
        }

        session[getter: .hasEmptySelection] = { true }

        session[getter: .hitTestingTarget] = { [weak self] in
            guard let self, let root = sceneView.scene?.rootNode else { return nil }
            let origin = self.session[.hitTestingOrigin].scnVector
            let direction = self.session[.hitTestingDirection].scnVector
            
            let length = 100000.0
            let end = SCNVector3(
                x: origin.x + direction.x * length,
                y: origin.y + direction.y * length,
                z: origin.z + direction.z * length
            )
            guard let result = root.hitTestWithSegment(from: origin, to: end, options: [
                SCNHitTestOption.searchMode.rawValue: NSNumber(value: SCNHitTestSearchMode.closest.rawValue),
                SCNHitTestOption.rootNode.rawValue: modelContainer
            ]).first else {
                return nil
            }

            /* print("Hit: \(result.worldCoordinates)")
             root.addChildNode(debugSphere)
            debugSphere.geometry?.firstMaterial?.diffuse.contents = NSColor.red
            debugSphere.position = result.worldCoordinates*/

            return .init(result.worldCoordinates)
        }

        do {
            try session.start(applicationName: "Model Viewer")
        } catch {
            print("NavLib initialization failed: \(error)")
        }

        notificationTokens.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeMainNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateNavLibFocus()
            }
        })
    }

    func updateNavLibFocus() {
        if let main = NSApp.mainWindow, NSDocumentController.shared.document(for: main) == document {
            setNavLibSessionActive()
        }
    }

    var navLibPointerPosition: SCNVector3? {
        guard var hoverPoint = hoverPoint else { return nil }
        hoverPoint.y = hoverPoint.y - sceneViewBounds.height
        return sceneView.unprojectPoint(SCNVector3(hoverPoint.x, hoverPoint.y, 0))
    }

    func updateNavLibPointerPosition() {
        guard let position = navLibPointerPosition else { return }
        session[.pointerPosition] = .init(position)
    }

    func updateNavLibProjection() {
        session[.viewIsPerspective] = cameraNode.camera?.usesOrthographicProjection == false
    }

    func updateNavLibTransform() {
        session[.cameraTransform] = .init(scnMatrix: cameraNode.transform)
    }

    func cancelNavLibMotion() {
        session[.motion] = false
    }

    func setNavLibSessionActive() {
        session[.active] = true
    }

    var orthographicViewExtents: navlib.box_t? {
        guard let camera = sceneView.pointOfView?.camera,
              camera.usesOrthographicProjection
        else { return nil }

        let height = camera.orthographicScale * 2
        let width = height * (sceneViewBounds.width / sceneViewBounds.height)

        let min = SCNVector3(-width / 2, -height / 2, camera.zNear)
        let max = SCNVector3(width / 2, height / 2, camera.zFar)
        return navlib.box_t(min: .init(min), max: .init(max))
    }

    func setNavLibSuspended(_ suspend: Bool) {
        navLibIsSuspended = suspend
        cancelNavLibMotion()
    }
}

import SceneKit
import simd

extension ViewportController {
    enum CameraProjection {
        case orthographic
        case perspective
    }

    /// Depth of the model's bounding-sphere center along the camera's view axis. This is the
    /// distance that governs a perspective camera's apparent size, and the reference used to
    /// keep the orthographic and perspective projections matched across a switch.
    private func modelCenterViewDepth() -> Double {
        guard let pov = sceneView.pointOfView else { return 0 }
        let center = sceneController.modelBoundingSphere.center
        let toCenter = simd_float3(Float(center.x), Float(center.y), Float(center.z)) - pov.simdWorldPosition
        return Double(simd_dot(toCenter, simd_normalize(pov.simdWorldFront)))
    }

    /// Preserve the model's apparent size when toggling projection. The two modes store
    /// "zoom" differently — orthographic in `orthographicScale`, perspective in the camera's
    /// distance — so we convert between them at the switch, using the model center's depth
    /// along the view axis as the shared reference. (Doing this only on the switch, rather
    /// than re-deriving the orthographic scale every frame, lets orthographic scroll-zoom
    /// stay put and makes round-trips between the modes exact.)
    func convertZoomForProjectionChange(to newProjection: CameraProjection) {
        guard let pov = sceneView.pointOfView, let camera = pov.camera else { return }
        let tanHalfFov = tan(camera.fieldOfView * (.pi / 180.0) / 2.0)
        guard tanHalfFov > 0 else { return }

        switch newProjection {
        case .orthographic:
            // Match the orthographic half-height to what perspective shows at the center.
            camera.orthographicScale = abs(modelCenterViewDepth()) * tanHalfFov
        case .perspective:
            // Dolly along the view axis so the center sits at the depth whose perspective
            // field of view spans the current orthographic half-height.
            let targetDepth = camera.orthographicScale / tanHalfFov
            let delta = Float(modelCenterViewDepth() - targetDepth)
            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            pov.simdWorldPosition += simd_normalize(pov.simdWorldFront) * delta
            SCNTransaction.commit()
        }
    }

    func updateCameraProjection() {
        guard let pov = sceneView.pointOfView,
              let camera = pov.camera else {
            return
        }

        // Interpret fieldOfView as the vertical half-angle. convertZoomForProjectionChange()
        // and the preset fit math both equate distance * tan(fov/2) to the orthographic
        // half-height, which only holds when the field of view is measured vertically.
        camera.projectionDirection = .vertical

        if projection == .orthographic {
            camera.usesOrthographicProjection = true
            camera.automaticallyAdjustsZRange = false
            camera.zNear = -100000
            camera.zFar = 100000
        } else {
            camera.usesOrthographicProjection = false
            camera.automaticallyAdjustsZRange = true
            camera.fieldOfView = 30
        }

        updateNavLibProjection()
    }
}

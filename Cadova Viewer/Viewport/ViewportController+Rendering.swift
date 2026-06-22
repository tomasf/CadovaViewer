import AppKit
import SceneKit
import ViewerCore

extension ViewportController: SCNSceneRendererDelegate {
    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        // Advance any post-release camera glide in lockstep with the render loop (no-op when idle).
        stepCameraInertia(atTime: time)

        // Apply the latest SpaceMouse-commanded transform here (render thread), so NavLib's setter
        // stays lock-free and never stalls the run loop on the scene lock.
        if let pending = pendingNavLibTransform.withLock({ value -> SCNMatrix4? in
            let latest = value
            value = nil
            return latest
        }) {
            cameraNode.transform = pending
        }

        grid.updateScale(renderer: sceneView, viewSize: sceneViewSize)
        measurementRenderer.updateScreenSizes(renderer: sceneView)

        // Track the active point-of-view node (SceneKit can swap it in). The headlight follows the
        // camera independently, in willRenderScene.
        if let currentCameraNode = sceneView.pointOfView, currentCameraNode != cameraNode {
            cameraNode = currentCameraNode
        }
    }

    func renderer(_ renderer: any SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        grid.updateVisibility(cameraNode: cameraNode)
        publishGridScaleIfNeeded()

        guard let pov = renderer.pointOfView?.presentation else { return }

        // Aim the headlight along the camera's view direction (both shine/look along their node's
        // -Z), so it reads as a light coming from the viewer.
        headlightNode.simdWorldOrientation = pov.simdWorldOrientation

        let indicatorValues = OrientationIndicatorValues(
            x: pov.convertVector(SCNVector3(1, 0, 0), from: nil),
            y: pov.convertVector(SCNVector3(0, 1, 0), from: nil),
            z: pov.convertVector(SCNVector3(0, 0, 1), from: nil)
        )

        coordinateIndicatorValueStream.send(indicatorValues)

        // Per frame: slide the gizmo to the view centre on its plane (using the live presentation
        // camera, `pov`, so it tracks during an orbit) and keep it a constant on-screen size.
        crossSectionGizmo.followView(presentationCamera: pov, isDragging: crossSectionDrag != nil)
        crossSectionGizmo.updateScreenScale(renderer: renderer)

        sceneView.applyEdgeDepthOffset(
            edgeNodes: modelInstance.edgeGeometryNodes,
            cameraNode: cameraNode,
            modelNode: modelInstance.root,
            viewSize: sceneViewSize
        )
        // Edge lines are left at Metal's default 1-pixel line width (≈0.5pt on a 2× display).
    }

    /// Pushes the grid's current scale to the legend, but only when it changes enough to matter:
    /// a new spacing decade, a visibility change, or a noticeable shift in the fine-grid fade. This
    /// keeps the (main-thread) UI update off the per-frame path while still tracking zoom.
    private func publishGridScaleIfNeeded() {
        let info = grid.scaleInfo
        if let last = lastSentGridScale,
           last.isVisible == info.isVisible,
           abs(last.coarseExponent - info.coarseExponent) < 0.01 {
            return
        }
        lastSentGridScale = info
        gridScaleStream.send(info)
    }
}

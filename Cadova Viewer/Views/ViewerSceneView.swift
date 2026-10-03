import SceneKit
import AppKit
import SwiftUI
import Combine
import ViewerCore

struct ViewerSceneView: NSViewRepresentable {
    let viewportController: ViewportController

    func makeCoordinator() -> ViewportController {
        viewportController
    }

    func makeNSView(context: Context) -> CustomSceneView {
        context.coordinator.sceneView
    }

    func updateNSView(_ sceneView: CustomSceneView, context: Context) {
        if !sceneView.isPaneResizeActive {
            context.coordinator.updateCameraProjection()
        }
    }
}

/// The app's viewport scene view. Camera navigation input comes from `NavigableSceneView` (shared with
/// the Quick Look preview); this adds viewport focus, the cross-section gizmo, keyboard handling and
/// pane-resize projection handling.
class CustomSceneView: NavigableSceneView {
    var onCancel: (() -> Void)? = nil
    /// Cross-section gizmo drag hooks. `beginGizmoDrag` returns true if a gizmo handle was grabbed at
    /// the point, in which case the drag is fed to `updateGizmoDrag` (view points) and `endGizmoDrag`
    /// is called at the end — taking precedence over camera control.
    var beginGizmoDrag: ((CGPoint) -> Bool)? = nil
    var updateGizmoDrag: ((CGPoint) -> Void)? = nil
    var endGizmoDrag: (() -> Void)? = nil
    weak var viewportController: ViewportController?

    override var preciseScrollZoomsByDefault: Bool {
        Preferences().preciseScrollAction == .zoom
    }

    /// A trackpad pinch or rotation focuses this viewport, like a click does.
    override func cameraGestureWillBegin() {
        viewportController?.requestFocus()
    }

    var isPaneResizeActive: Bool { paneResizeLiveResizeDepth > 0 }
    private var paneResizeLiveResizeDepth = 0
    private var paneResizeIsUsingHorizontalProjection = false

    override func layout() {
        super.layout()
        overlaySKScene?.size = bounds.size
    }

    func beginPaneResize(axis: SplitLayout.Axis) {
        if paneResizeLiveResizeDepth == 0 {
            super.viewWillStartLiveResize()
            setProjectionDirectionForPaneResize(axis: axis)
        }
        paneResizeLiveResizeDepth += 1
    }

    func endPaneResize() {
        guard paneResizeLiveResizeDepth > 0 else { return }
        paneResizeLiveResizeDepth -= 1
        if paneResizeLiveResizeDepth == 0 {
            restoreProjectionDirectionAfterPaneResize()
            super.viewDidEndLiveResize()
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let splitAnimationActive = viewportController?.documentViewModel?.animatingSplitID != nil
        if !splitAnimationActive {
            adjustCameraForResize(from: frame.size, to: newSize)
        }

        super.setFrameSize(newSize)
        viewportController?.sceneViewSize = newSize
    }

    private func setProjectionDirectionForPaneResize(axis: SplitLayout.Axis) {
        // A pane that starts a resize collapsed (the new pane grows in from the divider on a split)
        // has a degenerate size here, so the aspect-ratio conversion below would bake in a bogus
        // field of view. Skip it — it stays in the standard vertical projection and reveals as it
        // grows, which lands on the same final projection with no end-of-animation pop.
        guard bounds.width > 1, bounds.height > 1,
              axis == .horizontal,
              let camera = pointOfView?.camera,
              !camera.usesOrthographicProjection else { return }

        let verticalFieldOfView = currentVerticalFieldOfView(camera: camera, viewSize: bounds.size)
        paneResizeIsUsingHorizontalProjection = true

        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        camera.projectionDirection = .horizontal
        camera.fieldOfView = horizontalFieldOfView(forVerticalFieldOfView: verticalFieldOfView, viewSize: bounds.size)
        SCNTransaction.commit()
        setNeedsRedraw()
    }

    private func restoreProjectionDirectionAfterPaneResize() {
        guard paneResizeIsUsingHorizontalProjection else { return }
        paneResizeIsUsingHorizontalProjection = false

        guard let camera = pointOfView?.camera,
              !camera.usesOrthographicProjection else { return }

        let verticalFieldOfView = currentVerticalFieldOfView(camera: camera, viewSize: bounds.size)

        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        camera.projectionDirection = .vertical
        camera.fieldOfView = verticalFieldOfView
        SCNTransaction.commit()
        setNeedsRedraw()
    }

    private func currentVerticalFieldOfView(camera: SCNCamera, viewSize: NSSize) -> Double {
        if camera.projectionDirection == .horizontal {
            return verticalFieldOfView(forHorizontalFieldOfView: camera.fieldOfView, viewSize: viewSize)
        }
        return camera.fieldOfView
    }

    private func horizontalFieldOfView(forVerticalFieldOfView verticalFieldOfView: Double, viewSize: NSSize) -> Double {
        let aspectRatio = max(Double(viewSize.width), 1) / max(Double(viewSize.height), 1)
        return radiansToDegrees(2 * atan(tan(degreesToRadians(verticalFieldOfView) / 2) * aspectRatio))
    }

    private func verticalFieldOfView(forHorizontalFieldOfView horizontalFieldOfView: Double, viewSize: NSSize) -> Double {
        let aspectRatio = max(Double(viewSize.width), 1) / max(Double(viewSize.height), 1)
        return radiansToDegrees(2 * atan(tan(degreesToRadians(horizontalFieldOfView) / 2) / aspectRatio))
    }

    private func degreesToRadians(_ degrees: Double) -> Double {
        degrees * .pi / 180
    }

    private func radiansToDegrees(_ radians: Double) -> Double {
        radians * 180 / .pi
    }

    /// Orthographic cameras express their visible vertical span directly in points, so preserve the
    /// apparent scale while the pane height changes. Perspective cameras keep a fixed field of view;
    /// moving them during resize makes vertical split drags visibly settle after the drawable redraws.
    private func adjustCameraForResize(from oldSize: NSSize, to newSize: NSSize) {
        guard oldSize.height > 0, newSize.height > 0, oldSize.height != newSize.height,
              let pointOfView, let camera = pointOfView.camera else { return }

        let heightRatio = Double(newSize.height / oldSize.height)
        guard camera.usesOrthographicProjection else { return }

        SCNTransaction.begin()
        SCNTransaction.disableActions = true
        camera.orthographicScale *= heightRatio
        SCNTransaction.commit()
    }
}

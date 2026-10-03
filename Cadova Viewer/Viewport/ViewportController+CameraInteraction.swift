import SceneKit
import ViewerCore

/// Mouse/trackpad camera navigation lives in ViewerCore (`CameraNavigator`, driven by
/// `NavigableSceneView`), shared with the Quick Look preview. This supplies it with the viewport's
/// camera, model bounds and cross-section-aware picking.
extension ViewportController: CameraNavigatorDelegate {
    func cameraNode(for navigator: CameraNavigator) -> SCNNode {
        cameraNode
    }

    func modelBoundingSphere(for navigator: CameraNavigator) -> (center: SCNVector3, radius: Float) {
        sceneController.modelBoundingSphere
    }

    /// Only visible geometry counts when cuts are active: the kept side or a cap, never a clipped-away
    /// surface.
    func cameraNavigator(_ navigator: CameraNavigator, surfacePointAt viewPoint: CGPoint) -> SCNVector3? {
        nearestVisibleHit(at: viewPoint, in: modelInstance.root)?.worldCoordinates
    }

    func cameraNavigatorDidMoveCamera(_ navigator: CameraNavigator) {
        updateOrthographicDepthRange()
    }

    func cameraNavigatorWillTakeOver(_ navigator: CameraNavigator) {
        cancelCameraFlight()
    }

    func cameraNavigatorDidFinishMoving(_ navigator: CameraNavigator) {
        viewDidChange()
    }
}

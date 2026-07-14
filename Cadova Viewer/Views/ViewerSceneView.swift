import SceneKit
import AppKit
import SwiftUI
import Combine

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

enum TrackpadCameraGesture {
    case roll
    case zoom
}

class CustomSceneView: SCNView {
    var onClick: ((CGPoint) -> Void)? = nil
    var onHover: ((CGPoint?) -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    /// Cross-section gizmo drag hooks. `beginGizmoDrag` returns true if a gizmo handle was grabbed at
    /// the point, in which case the drag is fed to `updateGizmoDrag` (view points) and `endGizmoDrag`
    /// is called at the end — taking precedence over camera control.
    var beginGizmoDrag: ((CGPoint) -> Bool)? = nil
    var updateGizmoDrag: ((CGPoint) -> Void)? = nil
    var endGizmoDrag: (() -> Void)? = nil
    var mouseInteractionActive: AnyPublisher<Bool, Never> { mouseInteractionActiveSubject.eraseToAnyPublisher() }
    var mouseRotationPivot: AnyPublisher<SCNVector3?, Never> { mouseRotationPivotSubject.eraseToAnyPublisher() }
    var showContextMenu: AnyPublisher<NSEvent, Never> { contextMenuSubject.eraseToAnyPublisher() }
    weak var viewportController: ViewportController?
    /// Whether mouse/trackpad camera navigation is accepted. Turned off while a SpaceMouse motion is
    /// active (see `motionActiveChanged`) so the two don't fight. Replaces SceneKit's
    /// `allowsCameraControl`, which is now off — we drive the camera ourselves.
    var cameraControlEnabled = true

    /// Latched pan-vs-zoom decision for the current precise-scroll gesture. Momentum events (after
    /// lift-off) may no longer carry the modifier keys, so the mode is fixed during the fingers-down
    /// portion and reused through the inertial tail.
    var scrollGestureZooms = false

    /// In-progress trackpad rotation-gesture (roll) state, accumulated across the gesture's discrete
    /// phased events. See `rotate(with:)`.
    var rollDragState: ViewportController.CameraDragState?
    var rollAngle: Float = 0
    var rollVelocityTracker = RollVelocityTracker()

    /// In-progress trackpad pinch (zoom) state, accumulated across the gesture's discrete phased events.
    /// See `magnify(with:)`.
    var zoomDragState: ViewportController.CameraDragState?
    var zoomLogAmount: Float = 0
    var zoomVelocityTracker = ZoomVelocityTracker()

    /// A real two-finger twist almost always carries a tiny amount of pinch too, so AppKit delivers
    /// `rotate(with:)` and `magnify(with:)` concurrently from the same touches. Without this, that stray
    /// pinch would start its own independent zoom drag mid-roll, fighting the roll and feeling glitchy.
    /// Once one of the two gestures begins, it's latched here and the other is ignored entirely until the
    /// latched one ends.
    var activeTrackpadCameraGesture: TrackpadCameraGesture?

    let mouseInteractionActiveSubject = CurrentValueSubject<Bool, Never>(false)
    let mouseRotationPivotSubject = CurrentValueSubject<SCNVector3?, Never>(nil)
    let contextMenuSubject = PassthroughSubject<NSEvent, Never>()
    var hoverTrackingArea: NSTrackingArea?
    var isPaneResizeActive: Bool { paneResizeLiveResizeDepth > 0 }
    private var paneResizeLiveResizeDepth = 0
    private var paneResizeIsUsingHorizontalProjection = false

    override init(frame: NSRect, options: [String : Any]? = nil) {
        super.init(frame: frame, options: options)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

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
        guard axis == .horizontal,
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

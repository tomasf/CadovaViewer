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
        context.coordinator.updateCameraProjection()
    }
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

    let mouseInteractionActiveSubject = CurrentValueSubject<Bool, Never>(false)
    let mouseRotationPivotSubject = CurrentValueSubject<SCNVector3?, Never>(nil)
    let contextMenuSubject = PassthroughSubject<NSEvent, Never>()
    var hoverTrackingArea: NSTrackingArea?

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
}

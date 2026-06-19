import SceneKit
import AppKit
import SwiftUI
import ObjectiveC
import Combine
import Carbon.HIToolbox
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

    private enum CameraDragMode { case orbit, pan }
    /// Latched pan-vs-zoom decision for the current precise-scroll gesture. Momentum events (after
    /// lift-off) may no longer carry the modifier keys, so the mode is fixed during the fingers-down
    /// portion and reused through the inertial tail.
    private var scrollGestureZooms = false

    private let mouseInteractionActiveSubject = CurrentValueSubject<Bool, Never>(false)
    private let mouseRotationPivotSubject = CurrentValueSubject<SCNVector3?, Never>(nil)
    private let contextMenuSubject = PassthroughSubject<NSEvent, Never>()
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame: NSRect, options: [String : Any]? = nil) {
        super.init(frame: frame, options: options)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func rightMouseDown(with event: NSEvent) {
        viewportController?.requestFocus()
        runCameraDrag(with: event, mode: .pan)
    }

    // Camera drags read raw deltas through MouseTracker, so the drag/up events delivered by AppKit
    // are unused; swallow them rather than letting SCNView act on them.
    override func rightMouseDragged(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}

    override func layout() {
        super.layout()
        overlaySKScene?.size = bounds.size
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }

        let area = NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area

        super.updateTrackingAreas()
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let viewportController, cameraControlEnabled else { return }

        let point = convert(event.locationInWindow, from: nil)

        if event.hasPreciseScrollingDeltas {
            // While the fingers are down (no momentum) the modifiers are current, so (re)latch the
            // mode; the momentum tail then keeps it. Shift or Option zooms (toward the cursor),
            // otherwise pan. Momentum events flow through to both, which is what gives the glide.
            if event.momentumPhase == [] {
                scrollGestureZooms = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.option)
            }
            if scrollGestureZooms {
                // macOS reports the wheel on whichever axis dominates (Shift swaps Y→X); deltas are
                // points, so a gentle per-point sensitivity.
                let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
                viewportController.zoomCamera(factor: zoomFactor(forScrollDelta: delta, sensitivity: 0.01), towardViewPoint: point)
            } else {
                viewportController.panByScroll(dx: Float(event.scrollingDeltaX), dy: Float(event.scrollingDeltaY))
            }
        } else {
            // Classic mouse wheel: zoom toward the cursor. Deltas are ~1 per detent, so each detent
            // needs a much larger step than a trackpad point.
            viewportController.zoomCamera(factor: zoomFactor(forScrollDelta: event.scrollingDeltaY, sensitivity: 0.1), towardViewPoint: point)
        }
    }

    override func magnify(with event: NSEvent) {
        guard let viewportController, cameraControlEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        viewportController.zoomCamera(factor: 1 + Double(event.magnification), towardViewPoint: point)
    }

    private func zoomFactor(forScrollDelta delta: CGFloat, sensitivity: Double) -> Double {
        // Scrolling up (positive delta) zooms in. Exponential so each step is a constant ratio.
        return exp(Double(delta) * sensitivity)
    }

    override func mouseDown(with event: NSEvent) {
        // Any click (including the start of a camera drag) focuses this viewport.
        viewportController?.requestFocus()

        let localPoint = convert(event.locationInWindow, from: nil)

        // A left-press on a cross-section gizmo handle starts a manipulation, ahead of camera control.
        if beginGizmoDrag?(localPoint) == true {
            runGizmoDrag(with: event)
            return
        }

        // Option turns a left-drag into a pan; otherwise it orbits (Shift then locks to one axis).
        let mode: CameraDragMode = event.modifierFlags.contains(.option) ? .pan : .orbit
        runCameraDrag(with: event, mode: mode)
    }

    private func runGizmoDrag(with event: NSEvent) {
        mouseInteractionActiveSubject.send(true)
        NSCursor.hide()
        _ = MouseTracker.track(with: event) { [weak self] location in
            guard let self else { return }
            updateGizmoDrag?(convert(location, from: nil))
        }
        NSCursor.unhide()
        endGizmoDrag?()
        mouseInteractionActiveSubject.send(false)
    }

    /// Runs a camera orbit or pan, driven by raw deltas from `MouseTracker` (cursor locked). The
    /// drag mode and modifiers are fixed at the moment the button goes down. A press with no
    /// movement falls through to a click (left) or context menu (right).
    private func runCameraDrag(with event: NSEvent, mode: CameraDragMode) {
        guard let viewportController, cameraControlEnabled else { return }

        let localPoint = convert(event.locationInWindow, from: nil)
        let start = event.locationInWindow
        let dragState = viewportController.beginCameraDrag(atViewPoint: localPoint)
        let axisLockEnabled = mode == .orbit && event.modifierFlags.contains(.shift)

        mouseInteractionActiveSubject.send(true)

        // Locked drags freeze and hide the cursor and read raw deltas, so they can go forever without
        // the cursor hitting a screen edge: orbiting, and right-button panning. Option+left panning
        // stays unlocked, tracking the real cursor so the grabbed point sticks to it 1:1.
        let lockCursor = mode == .orbit || event.type == .rightMouseDown

        var didMove = false
        var axisLock: ViewportController.CameraAxisLock?
        // Release-velocity tracking, for the post-drag glide.
        var lastLocation = start
        var lastMoveTime = CACurrentMediaTime()
        var velocity = SIMD2<Float>.zero
        var lastDelta = SIMD2<Float>.zero
        let endEvent = MouseTracker.track(with: event, lockCursor: lockCursor) { [weak self] location in
            guard let self else { return }
            var dx = Float(location.x - start.x)
            var dy = Float(location.y - start.y)

            if !didMove {
                didMove = true
                // Defer the pivot indicator and cursor hiding until a real drag begins, so a plain
                // click doesn't flash the pivot dot.
                if lockCursor {
                    NSCursor.hide()
                }
                if mode == .orbit {
                    mouseRotationPivotSubject.send(SCNVector3(dragState.pivot))
                }
                if axisLockEnabled {
                    axisLock = abs(dx) >= abs(dy) ? .horizontal : .vertical
                }
            }

            switch axisLock {
            case .horizontal: dy = 0
            case .vertical: dx = 0
            case nil: break
            }

            // Track speed from each move (dt floored to avoid a tiny interval inflating it), lightly
            // smoothed. A pause shows up as low speed, so releasing after stopping won't fling.
            let now = CACurrentMediaTime()
            let dt = max(now - lastMoveTime, 1.0 / 60.0)
            let instant = SIMD2<Float>(Float(location.x - lastLocation.x), Float(location.y - lastLocation.y)) / Float(dt)
            velocity = instant * 0.6 + velocity * 0.4
            lastLocation = location
            lastMoveTime = now
            lastDelta = SIMD2(dx, dy)

            switch mode {
            case .orbit: viewportController.orbitCamera(dragState, dx: dx, dy: dy)
            case .pan: viewportController.panCamera(dragState, dx: dx, dy: dy)
            }
        }

        if didMove && lockCursor { NSCursor.unhide() }
        mouseRotationPivotSubject.send(nil)
        mouseInteractionActiveSubject.send(false)

        if didMove {
            // Coast on release — unless the drag had already stopped (a held, settled cursor).
            if CACurrentMediaTime() - lastMoveTime > 0.06 { velocity = .zero }
            if axisLock == .horizontal { velocity.y = 0 }
            if axisLock == .vertical { velocity.x = 0 }
            viewportController.startCameraInertia(dragState: dragState, delta: lastDelta, velocity: velocity, isOrbit: mode == .orbit)
        } else {
            switch endEvent.type {
            case .rightMouseUp: contextMenuSubject.send(endEvent)
            case .leftMouseUp: onClick?(localPoint)
            default: break
            }
        }
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case kVK_Escape:
            onCancel?()
        case kVK_Return, kVK_ANSI_KeypadEnter:
            // Return commits cross-section editing (the bar's "Done"); the SwiftUI overlay's default
            // action never fires because this NSView is first responder.
            if viewportController?.selectedCrossSectionID != nil {
                viewportController?.selectedCrossSectionID = nil
            } else {
                super.keyDown(with: event)
            }
        default:
            super.keyDown(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    private let snapshotScale = 2.0

    func snapshotImage(withBackground: Bool) -> NSImage? {
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.delegate = self
        renderer.scene = scene
        renderer.pointOfView = pointOfView
        renderer.debugOptions = debugOptions

        if withBackground == false {
            viewportController?.privateRoot.isHidden = true
        }

        let image = renderer.snapshot(
            atTime: sceneTime,
            with: CGSize(width: bounds.size.width * snapshotScale, height: bounds.size.height * snapshotScale),
            antialiasingMode: antialiasingMode
        )
        viewportController?.privateRoot.isHidden = false
        let rect = NSRect(origin: .zero, size: image.size)

        guard let imageRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(rect.width),
            pixelsHigh: Int(rect.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        guard let context = NSGraphicsContext(bitmapImageRep: imageRep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        if withBackground {
            backgroundColor.setFill()
            rect.fill()
        }
        image.draw(at: .zero, from: rect, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        let newImage = NSImage(size: rect.size)
        newImage.addRepresentation(imageRep)
        return newImage
    }

    func copySnapshot(withBackground: Bool) {
        guard let snapshot = snapshotImage(withBackground: withBackground) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([snapshot])
    }

    @IBAction @objc
    func copy(_ sender: Any?) {
        copySnapshot(withBackground: true)
    }

    @IBAction @objc
    func copyWithoutBackground(_ sender: Any?) {
        copySnapshot(withBackground: false)
    }
}


extension CustomSceneView: SCNSceneRendererDelegate {
    func renderer(_ renderer: any SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        renderer.currentRenderCommandEncoder?.setLineWidthPrivate(Float(snapshotScale))
    }
}

import AppKit
import SceneKit
import Combine

/// An `SCNView` that turns mouse and trackpad input into camera navigation through a `CameraNavigator`:
/// left-drag orbits (Option pans, Shift locks to one axis), right-drag pans, the wheel zooms toward the
/// cursor, precise scrolling pans (or zooms, with Shift/Option or `preciseScrollZoomsByDefault`), pinch
/// zooms and a two-finger twist rolls. Shared by the app and the Quick Look preview, so both navigate
/// identically. SceneKit's own `allowsCameraControl` should stay off.
open class NavigableSceneView: SCNView {
    /// The navigator that input drives. Owned elsewhere (by whoever owns the camera).
    public weak var cameraNavigator: CameraNavigator?

    /// Whether mouse/trackpad camera navigation is accepted, e.g. turned off while a SpaceMouse motion
    /// is active so the two don't fight.
    public var cameraControlEnabled = true

    /// A left press released without moving.
    public var onClick: ((CGPoint) -> Void)? = nil
    /// The cursor moved over the view (nil when it leaves).
    public var onHover: ((CGPoint?) -> Void)? = nil

    public var mouseInteractionActive: AnyPublisher<Bool, Never> { mouseInteractionActiveSubject.eraseToAnyPublisher() }
    /// The pivot of an in-progress orbit drag, nil when none.
    public var mouseRotationPivot: AnyPublisher<SCNVector3?, Never> { mouseRotationPivotSubject.eraseToAnyPublisher() }
    /// A right press released without moving.
    public var showContextMenu: AnyPublisher<NSEvent, Never> { contextMenuSubject.eraseToAnyPublisher() }

    public let mouseInteractionActiveSubject = CurrentValueSubject<Bool, Never>(false)
    public let mouseRotationPivotSubject = CurrentValueSubject<SCNVector3?, Never>(nil)
    public let contextMenuSubject = PassthroughSubject<NSEvent, Never>()

    /// Whether a precise scroll (trackpad / Magic Mouse) zooms rather than pans when no modifier is held.
    open var preciseScrollZoomsByDefault: Bool { false }

    /// How the cursor is handled during orbit and right-button pan drags.
    open var lockedDragCursorMode: MouseTracker.CursorMode { .locked }

    /// Called as a trackpad pinch or rotation gesture begins.
    open func cameraGestureWillBegin() {}

    private enum CameraDragMode { case orbit, pan }

    private enum TrackpadCameraGesture { case roll, zoom }

    /// Latched pan-vs-zoom decision for the current precise-scroll gesture. Momentum events (after
    /// lift-off) may no longer carry the modifier keys, so the mode is fixed during the fingers-down
    /// portion and reused through the inertial tail.
    private var scrollGestureZooms = false

    /// In-progress trackpad rotation-gesture (roll) state, accumulated across the gesture's discrete
    /// phased events. See `rotate(with:)`.
    private var rollDragState: CameraNavigator.DragState?
    private var rollAngle: Float = 0
    private var rollVelocityTracker = RollVelocityTracker()

    /// In-progress trackpad pinch (zoom) state, accumulated across the gesture's discrete phased events.
    /// See `magnify(with:)`.
    private var zoomDragState: CameraNavigator.DragState?
    private var zoomLogAmount: Float = 0
    private var zoomVelocityTracker = ZoomVelocityTracker()

    /// A real two-finger twist almost always carries a tiny amount of pinch too, so AppKit delivers
    /// `rotate(with:)` and `magnify(with:)` concurrently from the same touches. Without this, that stray
    /// pinch would start its own independent zoom drag mid-roll, fighting the roll and feeling glitchy.
    /// Once one of the two gestures begins, it's latched here and the other is ignored entirely until the
    /// latched one ends.
    private var activeTrackpadCameraGesture: TrackpadCameraGesture?

    private var hoverTrackingArea: NSTrackingArea?

    public override init(frame: NSRect, options: [String: Any]? = nil) {
        super.init(frame: frame, options: options)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    open override var acceptsFirstResponder: Bool { true }

    // MARK: - Mouse buttons

    open override func mouseDown(with event: NSEvent) {
        // Option turns a left-drag into a pan; otherwise it orbits (Shift then locks to one axis).
        let mode: CameraDragMode = event.modifierFlags.contains(.option) ? .pan : .orbit
        runCameraDrag(with: event, mode: mode)
    }

    open override func rightMouseDown(with event: NSEvent) {
        runCameraDrag(with: event, mode: .pan)
    }

    // Camera drags read deltas through MouseTracker, so the drag/up events delivered by AppKit are
    // unused; swallow them rather than letting SCNView act on them.
    open override func rightMouseDragged(with event: NSEvent) {}
    open override func rightMouseUp(with event: NSEvent) {}
    open override func mouseDragged(with event: NSEvent) {}
    open override func mouseUp(with event: NSEvent) {}

    // MARK: - Hover

    open override func updateTrackingAreas() {
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

    open override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        // The cursor moved, so the cached zoom-toward-cursor pivot is stale.
        cameraNavigator?.resetZoomPivot()
        onHover?(convert(event.locationInWindow, from: nil))
    }

    open override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        cameraNavigator?.resetZoomPivot()
        onHover?(convert(event.locationInWindow, from: nil))
    }

    open override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
    }

    // MARK: - Scroll / trackpad gestures

    open override func scrollWheel(with event: NSEvent) {
        guard let cameraNavigator, cameraControlEnabled else { return }

        let point = convert(event.locationInWindow, from: nil)

        if event.hasPreciseScrollingDeltas {
            // While the fingers are down (no momentum) the modifiers are current, so (re)latch the
            // mode; the momentum tail then keeps it. Shift or Option always zooms toward the cursor.
            if event.momentumPhase == [] {
                scrollGestureZooms =
                    preciseScrollZoomsByDefault ||
                    event.modifierFlags.contains(.shift) ||
                    event.modifierFlags.contains(.option)
            }
            if scrollGestureZooms {
                // macOS reports the wheel on whichever axis dominates (Shift swaps Y->X); deltas are
                // points, so a gentle per-point sensitivity.
                let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) ? event.scrollingDeltaY : event.scrollingDeltaX
                cameraNavigator.zoom(factor: zoomFactor(forScrollDelta: delta, sensitivity: 0.01), towardViewPoint: point)
            } else {
                cameraNavigator.panByScroll(dx: Float(event.scrollingDeltaX), dy: Float(event.scrollingDeltaY))
            }
        } else {
            // Classic mouse wheel: zoom toward the cursor. Deltas are ~1 per detent, so each detent
            // needs a much larger step than a trackpad point.
            cameraNavigator.zoom(factor: zoomFactor(forScrollDelta: event.scrollingDeltaY, sensitivity: 0.1), towardViewPoint: point)
        }
    }

    /// Trackpad pinch gesture → zoom toward the pinch centre. Like `rotate(with:)` (and unlike the
    /// synchronous orbit/pan `MouseTracker` loop), this arrives as discrete phased events, so a
    /// cumulative log-zoom is accumulated across them (applied rigidly from the drag-start pose, so it's
    /// drift-free) and a glide is started on release.
    open override func magnify(with event: NSEvent) {
        guard let cameraNavigator, cameraControlEnabled else { return }
        // A twist almost always carries a trace of pinch, so AppKit delivers this alongside rotate(with:)
        // from the same touches; ignore it entirely for the duration of an active roll rather than let it
        // fight the roll with a concurrent zoom drag.
        guard activeTrackpadCameraGesture != .roll else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch event.phase {
        case .began:
            cameraGestureWillBegin()
            mouseInteractionActiveSubject.send(true)
            activeTrackpadCameraGesture = .zoom
            // beginDrag cancels any ongoing glide and hit-tests the pivot under the cursor.
            zoomDragState = cameraNavigator.beginDrag(atViewPoint: point)
            zoomLogAmount = 0
            zoomVelocityTracker = ZoomVelocityTracker()
        case .changed:
            guard let state = zoomDragState else { return }
            // event.magnification is the per-event fractional change (factor − 1); accumulate its log so
            // the total is an exponential dolly (factor = e^zoomLogAmount).
            zoomLogAmount += log(1 + max(Float(event.magnification), -0.99))
            zoomVelocityTracker.record(logZoom: zoomLogAmount)
            cameraNavigator.zoom(state, logZoom: zoomLogAmount)
        case .ended, .cancelled:
            defer {
                zoomDragState = nil
                activeTrackpadCameraGesture = nil
                mouseInteractionActiveSubject.send(false)
            }
            guard let state = zoomDragState else { return }
            cameraNavigator.startInertia(
                dragState: state,
                delta: SIMD2(zoomLogAmount, 0),
                velocity: SIMD2(zoomVelocityTracker.release(), 0),
                motion: .zoom
            )
        default:
            break
        }
    }

    /// Trackpad two-finger rotation gesture → roll about the screen-depth axis (like SceneKit's native
    /// interaction). Unlike orbit/pan (a synchronous `MouseTracker` loop), this arrives as discrete
    /// phased events, so the angle is accumulated across them and a glide is started on release.
    open override func rotate(with event: NSEvent) {
        guard let cameraNavigator, cameraControlEnabled else { return }
        // A twist almost always carries a trace of pinch, so AppKit delivers magnify(with:) alongside
        // this from the same touches; ignore it entirely for the duration of an active zoom rather than
        // let it fight the pinch with a concurrent roll drag.
        guard activeTrackpadCameraGesture != .zoom else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch event.phase {
        case .began:
            cameraGestureWillBegin()
            mouseInteractionActiveSubject.send(true)
            activeTrackpadCameraGesture = .roll
            // beginDrag cancels any ongoing glide and hit-tests the pivot under the cursor.
            rollDragState = cameraNavigator.beginDrag(atViewPoint: point)
            rollAngle = 0
            rollVelocityTracker = RollVelocityTracker()
        case .changed:
            guard let state = rollDragState else { return }
            // NSEvent.rotation is the per-event delta in degrees (CCW positive); accumulate a total so
            // the view tracks the fingers, and apply in radians.
            rollAngle += Float(event.rotation) * .pi / 180
            rollVelocityTracker.record(angle: rollAngle)
            cameraNavigator.roll(state, angle: rollAngle)
        case .ended, .cancelled:
            defer {
                rollDragState = nil
                activeTrackpadCameraGesture = nil
                mouseInteractionActiveSubject.send(false)
            }
            guard let state = rollDragState else { return }
            cameraNavigator.startInertia(
                dragState: state,
                delta: SIMD2(rollAngle, 0),
                velocity: SIMD2(rollVelocityTracker.release(), 0),
                motion: .roll
            )
        default:
            break
        }
    }

    private func zoomFactor(forScrollDelta delta: CGFloat, sensitivity: Double) -> Double {
        // Scrolling up (positive delta) zooms in. Exponential so each step is a constant ratio.
        return exp(Double(delta) * sensitivity)
    }

    // MARK: - Camera drags

    /// Runs a camera orbit or pan, driven by deltas from `MouseTracker`. The drag mode and modifiers are
    /// fixed at the moment the button goes down. A press with no movement falls through to a click
    /// (left) or context menu (right).
    private func runCameraDrag(with event: NSEvent, mode: CameraDragMode) {
        guard let cameraNavigator, cameraControlEnabled else { return }

        let localPoint = convert(event.locationInWindow, from: nil)
        let start = event.locationInWindow
        guard let dragState = cameraNavigator.beginDrag(atViewPoint: localPoint) else { return }
        let axisLockEnabled = mode == .orbit && event.modifierFlags.contains(.shift)
        let cursorMode = cursorMode(for: event, mode: mode)
        let hidesCursor = cursorMode != .free

        mouseInteractionActiveSubject.send(true)

        var didMove = false
        var axisLock: CameraNavigator.AxisLock?
        var velocityTracker = CameraDragVelocityTracker(start: start)
        let endEvent = MouseTracker.track(with: event, cursorMode: cursorMode) { location in
            var delta = SIMD2<Float>(Float(location.x - start.x), Float(location.y - start.y))

            if !didMove {
                didMove = true
                // Defer the pivot indicator and cursor hiding until a real drag begins, so a plain click
                // doesn't flash the pivot dot.
                if hidesCursor {
                    NSCursor.hide()
                }
                if mode == .orbit {
                    mouseRotationPivotSubject.send(SCNVector3(dragState.pivot))
                }
                if axisLockEnabled {
                    axisLock = abs(delta.x) >= abs(delta.y) ? .horizontal : .vertical
                }
            }

            switch axisLock {
            case .horizontal: delta.y = 0
            case .vertical: delta.x = 0
            case nil: break
            }
            velocityTracker.record(location: location, delta: delta)

            switch mode {
            case .orbit: cameraNavigator.orbit(dragState, dx: delta.x, dy: delta.y)
            case .pan: cameraNavigator.pan(dragState, dx: delta.x, dy: delta.y)
            }
        }

        if didMove && hidesCursor { NSCursor.unhide() }
        mouseRotationPivotSubject.send(nil)
        mouseInteractionActiveSubject.send(false)

        if didMove {
            let inertia = velocityTracker.inertia(axisLock: axisLock)
            cameraNavigator.startInertia(dragState: dragState, delta: inertia.delta, velocity: inertia.velocity, motion: mode == .orbit ? .orbit : .pan)
        } else {
            switch endEvent.type {
            case .rightMouseUp: contextMenuSubject.send(endEvent)
            case .leftMouseUp: onClick?(localPoint)
            default: break
            }
        }
    }

    private func cursorMode(for event: NSEvent, mode: CameraDragMode) -> MouseTracker.CursorMode {
        // Locked drags freeze and hide the cursor and read deltas, so they can go forever without the
        // cursor hitting a screen edge: orbiting, and right-button panning. Option+left panning stays
        // unlocked, tracking the real cursor so the grabbed point sticks to it 1:1.
        mode == .orbit || event.type == .rightMouseDown ? lockedDragCursorMode : .free
    }
}

private struct CameraDragVelocityTracker {
    var lastLocation: CGPoint
    var lastMoveTime: CFTimeInterval
    var velocity = SIMD2<Float>.zero
    var delta = SIMD2<Float>.zero

    init(start: CGPoint) {
        lastLocation = start
        lastMoveTime = CACurrentMediaTime()
    }

    mutating func record(location: CGPoint, delta: SIMD2<Float>) {
        // Track speed from each move (dt floored to avoid a tiny interval inflating it), lightly
        // smoothed. A pause shows up as low speed, so releasing after stopping won't fling.
        let now = CACurrentMediaTime()
        let dt = max(now - lastMoveTime, 1.0 / 60.0)
        let instant = SIMD2<Float>(Float(location.x - lastLocation.x), Float(location.y - lastLocation.y)) / Float(dt)
        velocity = instant * 0.6 + velocity * 0.4
        lastLocation = location
        lastMoveTime = now
        self.delta = delta
    }

    func inertia(axisLock: CameraNavigator.AxisLock?) -> (delta: SIMD2<Float>, velocity: SIMD2<Float>) {
        var velocity = CACurrentMediaTime() - lastMoveTime > 0.06 ? .zero : self.velocity
        if axisLock == .horizontal { velocity.y = 0 }
        if axisLock == .vertical { velocity.x = 0 }
        return (delta, velocity)
    }
}

/// Tracks angular speed (radians/sec) across the discrete events of a trackpad rotation gesture, so
/// the post-release roll glide starts at the right speed. Mirrors `CameraDragVelocityTracker`: lightly
/// smoothed, and zeroed if released after a pause so a deliberate stop doesn't fling.
private struct RollVelocityTracker {
    private var lastAngle: Float = 0
    private var lastMoveTime = CACurrentMediaTime()
    private var velocity: Float = 0

    mutating func record(angle: Float) {
        let now = CACurrentMediaTime()
        let dt = max(now - lastMoveTime, 1.0 / 60.0)
        let instant = (angle - lastAngle) / Float(dt)
        velocity = instant * 0.6 + velocity * 0.4
        lastAngle = angle
        lastMoveTime = now
    }

    /// Release speed (radians/sec), zero if the gesture stalled before lifting off.
    func release() -> Float {
        CACurrentMediaTime() - lastMoveTime > 0.06 ? 0 : velocity
    }
}

/// Tracks zoom speed (log-zoom units/sec, i.e. the rate of exponential dolly) across the discrete
/// events of a trackpad pinch, so the post-release zoom glide starts at the right speed. Mirrors
/// `RollVelocityTracker`: lightly smoothed, and zeroed if released after a pause so a deliberate stop
/// doesn't fling.
private struct ZoomVelocityTracker {
    private var lastLogZoom: Float = 0
    private var lastMoveTime = CACurrentMediaTime()
    private var velocity: Float = 0

    mutating func record(logZoom: Float) {
        let now = CACurrentMediaTime()
        let dt = max(now - lastMoveTime, 1.0 / 60.0)
        let instant = (logZoom - lastLogZoom) / Float(dt)
        velocity = instant * 0.6 + velocity * 0.4
        lastLogZoom = logZoom
        lastMoveTime = now
    }

    /// Release speed (log-zoom units/sec), zero if the pinch stalled before lifting off.
    func release() -> Float {
        CACurrentMediaTime() - lastMoveTime > 0.06 ? 0 : velocity
    }
}

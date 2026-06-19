import AppKit
import SceneKit

extension CustomSceneView {
    enum CameraDragMode { case orbit, pan }

    func runGizmoDrag(with event: NSEvent) {
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
    func runCameraDrag(with event: NSEvent, mode: CameraDragMode) {
        guard let viewportController, cameraControlEnabled else { return }

        let localPoint = convert(event.locationInWindow, from: nil)
        let start = event.locationInWindow
        let dragState = viewportController.beginCameraDrag(atViewPoint: localPoint)
        let axisLockEnabled = mode == .orbit && event.modifierFlags.contains(.shift)
        let lockCursor = shouldLockCursor(for: event, mode: mode)

        mouseInteractionActiveSubject.send(true)

        var didMove = false
        var axisLock: ViewportController.CameraAxisLock?
        var velocityTracker = CameraDragVelocityTracker(start: start)
        let endEvent = MouseTracker.track(with: event, lockCursor: lockCursor) { [weak self] location in
            guard let self else { return }
            var delta = SIMD2<Float>(Float(location.x - start.x), Float(location.y - start.y))

            if !didMove {
                didMove = true
                beginCameraMovement(dragState: dragState, delta: delta, mode: mode, lockCursor: lockCursor, axisLockEnabled: axisLockEnabled, axisLock: &axisLock)
            }

            delta = apply(axisLock: axisLock, to: delta)
            velocityTracker.record(location: location, delta: delta)

            switch mode {
            case .orbit: viewportController.orbitCamera(dragState, dx: delta.x, dy: delta.y)
            case .pan: viewportController.panCamera(dragState, dx: delta.x, dy: delta.y)
            }
        }

        finishCameraDrag(
            endEvent: endEvent,
            didMove: didMove,
            dragState: dragState,
            localPoint: localPoint,
            mode: mode,
            lockCursor: lockCursor,
            axisLock: axisLock,
            velocityTracker: velocityTracker
        )
    }

    private func shouldLockCursor(for event: NSEvent, mode: CameraDragMode) -> Bool {
        // Locked drags freeze and hide the cursor and read raw deltas, so they can go forever without
        // the cursor hitting a screen edge: orbiting, and right-button panning. Option+left panning
        // stays unlocked, tracking the real cursor so the grabbed point sticks to it 1:1.
        return mode == .orbit || event.type == .rightMouseDown
    }

    private func beginCameraMovement(
        dragState: ViewportController.CameraDragState,
        delta: SIMD2<Float>,
        mode: CameraDragMode,
        lockCursor: Bool,
        axisLockEnabled: Bool,
        axisLock: inout ViewportController.CameraAxisLock?
    ) {
        // Defer the pivot indicator and cursor hiding until a real drag begins, so a plain click
        // doesn't flash the pivot dot.
        if lockCursor {
            NSCursor.hide()
        }
        if mode == .orbit {
            mouseRotationPivotSubject.send(SCNVector3(dragState.pivot))
        }
        if axisLockEnabled {
            axisLock = abs(delta.x) >= abs(delta.y) ? .horizontal : .vertical
        }
    }

    private func apply(axisLock: ViewportController.CameraAxisLock?, to delta: SIMD2<Float>) -> SIMD2<Float> {
        switch axisLock {
        case .horizontal: return SIMD2(delta.x, 0)
        case .vertical: return SIMD2(0, delta.y)
        case nil: return delta
        }
    }

    private func finishCameraDrag(
        endEvent: NSEvent,
        didMove: Bool,
        dragState: ViewportController.CameraDragState,
        localPoint: CGPoint,
        mode: CameraDragMode,
        lockCursor: Bool,
        axisLock: ViewportController.CameraAxisLock?,
        velocityTracker: CameraDragVelocityTracker
    ) {
        if didMove && lockCursor { NSCursor.unhide() }
        mouseRotationPivotSubject.send(nil)
        mouseInteractionActiveSubject.send(false)

        if didMove {
            let inertia = velocityTracker.inertia(axisLock: axisLock)
            viewportController?.startCameraInertia(dragState: dragState, delta: inertia.delta, velocity: inertia.velocity, isOrbit: mode == .orbit)
        } else {
            switch endEvent.type {
            case .rightMouseUp: contextMenuSubject.send(endEvent)
            case .leftMouseUp: onClick?(localPoint)
            default: break
            }
        }
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

    func inertia(axisLock: ViewportController.CameraAxisLock?) -> (delta: SIMD2<Float>, velocity: SIMD2<Float>) {
        var velocity = CACurrentMediaTime() - lastMoveTime > 0.06 ? .zero : self.velocity
        if axisLock == .horizontal { velocity.y = 0 }
        if axisLock == .vertical { velocity.x = 0 }
        return (delta, velocity)
    }
}

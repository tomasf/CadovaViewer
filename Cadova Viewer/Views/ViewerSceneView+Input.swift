import AppKit
import SceneKit
import Carbon.HIToolbox

extension CustomSceneView {
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
            // mode; the momentum tail then keeps it. The preference chooses the default precise
            // scroll behavior, and Shift or Option always zooms toward the cursor.
            if event.momentumPhase == [] {
                scrollGestureZooms =
                    Preferences().preciseScrollAction == .zoom ||
                    event.modifierFlags.contains(.shift) ||
                    event.modifierFlags.contains(.option)
            }
            if scrollGestureZooms {
                // macOS reports the wheel on whichever axis dominates (Shift swaps Y->X); deltas are
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

    /// Trackpad two-finger rotation gesture → roll about the screen-depth axis (like SceneKit's native
    /// interaction). Unlike orbit/pan (a synchronous `MouseTracker` loop), this arrives as discrete
    /// phased events, so the angle is accumulated across them and a glide is started on release.
    override func rotate(with event: NSEvent) {
        guard let viewportController, cameraControlEnabled else { return }
        let point = convert(event.locationInWindow, from: nil)
        switch event.phase {
        case .began:
            viewportController.requestFocus()
            mouseInteractionActiveSubject.send(true)
            // beginCameraDrag cancels any ongoing glide and hit-tests the pivot under the cursor.
            rollDragState = viewportController.beginCameraDrag(atViewPoint: point)
            rollAngle = 0
            rollVelocityTracker = RollVelocityTracker()
        case .changed:
            guard let state = rollDragState else { return }
            // NSEvent.rotation is the per-event delta in degrees (CCW positive); accumulate a total so
            // the view tracks the fingers, and apply in radians.
            rollAngle += Float(event.rotation) * .pi / 180
            rollVelocityTracker.record(angle: rollAngle)
            viewportController.rollCamera(state, angle: rollAngle)
        case .ended, .cancelled:
            defer {
                rollDragState = nil
                mouseInteractionActiveSubject.send(false)
            }
            guard let state = rollDragState else { return }
            viewportController.startCameraInertia(
                dragState: state,
                delta: SIMD2(rollAngle, 0),
                velocity: SIMD2(rollVelocityTracker.release(), 0),
                mode: .roll
            )
        default:
            break
        }
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

    func zoomFactor(forScrollDelta delta: CGFloat, sensitivity: Double) -> Double {
        // Scrolling up (positive delta) zooms in. Exponential so each step is a constant ratio.
        return exp(Double(delta) * sensitivity)
    }
}

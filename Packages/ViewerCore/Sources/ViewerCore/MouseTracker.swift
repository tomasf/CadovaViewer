import AppKit

/// Tracks mouse movement during a drag, reporting the cursor location to `moved` until the button is
/// released (the up event is returned).
public enum MouseTracker {
    public enum CursorMode {
        /// The cursor moves normally and `moved` reports the real event location (pointer acceleration
        /// included), so a grabbed point tracks the cursor 1:1 — used for Option-panning.
        case free
        /// The cursor is frozen in place and `moved` reports a location accumulated from the window
        /// server's mouse deltas, so a drag can continue forever without hitting the screen edge.
        case locked
        /// Like `locked`, but accumulating the drag events' own deltas. For views hosted out of process
        /// (Quick Look), which receive forwarded events and may not see window-server deltas. If the
        /// cursor can't be frozen there, the drag still works; it just moves the cursor.
        case lockedUsingEventDeltas
    }

    @discardableResult
    public static func track(with startEvent: NSEvent, cursorMode: CursorMode = .locked, moved: (NSPoint) -> Void) -> NSEvent {
        // Pull events from the window rather than `NSApp`, which isn't available in app extensions.
        guard let window = startEvent.window else { return startEvent }

        let endMask: NSEvent.EventTypeMask
        let dragMask: NSEvent.EventTypeMask
        switch startEvent.type {
        case .leftMouseDown: endMask = .leftMouseUp; dragMask = .leftMouseDragged
        case .rightMouseDown: endMask = .rightMouseUp; dragMask = .rightMouseDragged
        default: fatalError("Unsupported event type: \(startEvent.type)")
        }

        func isEnd(_ event: NSEvent) -> Bool {
            event.type == .leftMouseUp || event.type == .rightMouseUp
        }

        switch cursorMode {
        case .free:
            // Real-position tracking: let the cursor move and report where it actually is.
            while true {
                guard let event = window.nextEvent(matching: [endMask, dragMask], until: .distantFuture, inMode: .default, dequeue: true) else { continue }
                if isEnd(event) {
                    return event
                }
                moved(event.locationInWindow)
            }

        case .lockedUsingEventDeltas:
            CGAssociateMouseAndMouseCursorPosition(0)
            defer { CGAssociateMouseAndMouseCursorPosition(1) }
            var location = startEvent.locationInWindow
            while true {
                guard let event = window.nextEvent(matching: [endMask, dragMask], until: .distantFuture, inMode: .default, dequeue: true) else { continue }
                if isEnd(event) {
                    return event
                }
                // Event deltas are y-down.
                location.x += event.deltaX
                location.y -= event.deltaY
                if event.deltaX != 0 || event.deltaY != 0 {
                    moved(location)
                }
            }

        case .locked:
            CGAssociateMouseAndMouseCursorPosition(0)
            _ = CGGetLastMouseDelta() // Clear accumulated delta

            var location = startEvent.locationInWindow

            while true {
                if let event = window.nextEvent(matching: endMask, until: .now.addingTimeInterval(0.001), inMode: .default, dequeue: true) {
                    CGAssociateMouseAndMouseCursorPosition(1)
                    return event
                }

                let (deltaX, deltaY) = CGGetLastMouseDelta()
                location.x += CGFloat(deltaX)
                location.y -= CGFloat(deltaY)
                if deltaX != 0 || deltaY != 0 {
                    moved(location)
                }
            }
        }
    }
}

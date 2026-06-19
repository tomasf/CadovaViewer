import Cocoa

// Tracks mouse movement during a drag, reporting the cursor location to `moved` until the button is
// released (the up event is returned).
//
// `lockCursor` (the default) freezes the cursor in place and reports a location accumulated from raw
// device deltas, so a drag can continue forever without hitting the screen edge — used for orbiting.
// With `lockCursor: false` the cursor moves normally and `moved` reports the real event location
// (pointer acceleration included), so a grabbed point tracks the cursor 1:1 — used for panning.
class MouseTracker {
    @discardableResult
    static func track(with startEvent: NSEvent, lockCursor: Bool = true, moved: (NSPoint) -> Void) -> NSEvent {
        let endMask: NSEvent.EventTypeMask
        let dragMask: NSEvent.EventTypeMask
        switch startEvent.type {
        case .leftMouseDown: endMask = .leftMouseUp; dragMask = .leftMouseDragged
        case .rightMouseDown: endMask = .rightMouseUp; dragMask = .rightMouseDragged
        default: fatalError("Unsupported event type: \(startEvent.type)")
        }

        guard lockCursor else {
            // Real-position tracking: let the cursor move and report where it actually is.
            while true {
                guard let event = NSApp.nextEvent(matching: [endMask, dragMask], until: .distantFuture, inMode: .default, dequeue: true) else { continue }
                if event.type == .leftMouseUp || event.type == .rightMouseUp {
                    return event
                }
                moved(event.locationInWindow)
            }
        }

        CGAssociateMouseAndMouseCursorPosition(0)
        _ = CGGetLastMouseDelta() // Clear accumulated delta

        var location = startEvent.locationInWindow

        while true {
            if let event = NSApp.nextEvent(matching: endMask, until: .now.addingTimeInterval(0.001), inMode: .default, dequeue: true) {
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

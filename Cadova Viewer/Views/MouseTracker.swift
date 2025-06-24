import Cocoa

// Used to track mouse movement while locking the cursor position
class MouseTracker {
    @discardableResult
    static func track(with startEvent: NSEvent, moved: (NSPoint) -> Void) -> NSEvent {
        CGAssociateMouseAndMouseCursorPosition(0)
        _ = CGGetLastMouseDelta() // Clear accumulated delta

        var location = startEvent.locationInWindow

        let endEventMask: NSEvent.EventTypeMask
        switch startEvent.type {
        case .leftMouseDown: endEventMask = .leftMouseUp
        case .rightMouseDown: endEventMask = .rightMouseUp
        default: fatalError("Unsupported event type: \(startEvent.type)")
        }

        while true {
            if let event = NSApp.nextEvent(matching: endEventMask, until: .now.addingTimeInterval(0.001), inMode: .default, dequeue: true) {
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

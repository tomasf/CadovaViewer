import AppKit
import SceneKit
import Carbon.HIToolbox
import ViewerCore

/// Input on top of `NavigableSceneView`'s camera navigation: clicks focus the viewport, and a left
/// press on a cross-section gizmo handle manipulates it instead of moving the camera.
extension CustomSceneView {
    override func mouseDown(with event: NSEvent) {
        // Any click (including the start of a camera drag) focuses this viewport.
        viewportController?.requestFocus()

        // A left-press on a cross-section gizmo handle starts a manipulation, ahead of camera control.
        if beginGizmoDrag?(convert(event.locationInWindow, from: nil)) == true {
            runGizmoDrag(with: event)
            return
        }

        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        viewportController?.requestFocus()
        super.rightMouseDown(with: event)
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
}

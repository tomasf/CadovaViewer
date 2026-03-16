import SceneKit
import AppKit
import ViewerCore

class PreviewSceneView: SCNView {
    weak var modelNode: SCNNode?

    private func updateOrbitTarget(for event: NSEvent) {
        guard let modelNode else { return }
        let localPoint = convert(event.locationInWindow, from: nil)

        if let result = hitTest(localPoint, options: [
            .searchMode: SCNHitTestSearchMode.all.rawValue as NSNumber,
            .rootNode: modelNode
        ]).first {
            defaultCameraController.target = result.worldCoordinates
        } else {
            defaultCameraController.target = xyPlanePoint(forViewPoint: localPoint)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        updateOrbitTarget(for: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        NSEvent.overriddenModifierFlags = .option
        super.mouseDown(with: event)
        updateOrbitTarget(for: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        NSEvent.overriddenModifierFlags = nil
        super.mouseUp(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        if !event.hasPreciseScrollingDeltas {
            NSEvent.overriddenModifierFlags = .option
            super.scrollWheel(with: event)
            NSEvent.overriddenModifierFlags = nil
        } else {
            super.scrollWheel(with: event)
        }
    }

    override var acceptsFirstResponder: Bool { true }
}

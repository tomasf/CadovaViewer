import SceneKit
import AppKit
import ViewerCore

class PreviewSceneView: SCNView {
    weak var modelNode: SCNNode?

    /// The world point to orbit/pan around for a press: the surface under the cursor, else the grid.
    private func orbitTarget(for event: NSEvent) -> SCNVector3 {
        let localPoint = convert(event.locationInWindow, from: nil)
        if let modelNode, let result = hitTest(localPoint, options: [
            .searchMode: SCNHitTestSearchMode.all.rawValue as NSNumber,
            .rootNode: modelNode
        ]).first {
            return result.worldCoordinates
        }
        return xyPlanePoint(forViewPoint: localPoint)
    }

    override func mouseDown(with event: NSEvent) {
        defaultCameraController.target = orbitTarget(for: event)
        super.mouseDown(with: event) // built-in turntable orbit
    }

    // The built-in controller only orbits, so drive right-drag pan and wheel zoom directly through
    // the camera controller (replacing the old option-key modifier swizzle).
    override func rightMouseDown(with event: NSEvent) {
        defaultCameraController.target = orbitTarget(for: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        let scale = panScale()
        defaultCameraController.translateInCameraSpaceBy(
            x: Float(-event.deltaX) * scale,
            y: Float(event.deltaY) * scale,
            z: 0
        )
    }

    override func scrollWheel(with event: NSEvent) {
        if event.hasPreciseScrollingDeltas {
            let scale = panScale()
            defaultCameraController.translateInCameraSpaceBy(
                x: Float(-event.scrollingDeltaX) * scale,
                y: Float(event.scrollingDeltaY) * scale,
                z: 0
            )
        } else {
            // Classic wheel: dolly along the view axis (scroll up = zoom in).
            defaultCameraController.translateInCameraSpaceBy(x: 0, y: 0, z: Float(-event.scrollingDeltaY) * panScale())
        }
    }

    /// World units per point, scaled by the distance to the orbit target so pan/zoom feel consistent
    /// regardless of model size.
    private func panScale() -> Float {
        guard let pov = pointOfView else { return 1 }
        let distance = defaultCameraController.target.distance(from: pov.worldPosition)
        return Float(max(distance, 1) / max(bounds.height, 1))
    }

    override var acceptsFirstResponder: Bool { true }
}

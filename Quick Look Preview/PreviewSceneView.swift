import SceneKit
import AppKit
import ViewerCore

/// The preview's scene view. Navigation input is the app's own (`NavigableSceneView`), so the preview
/// orbits, pans and zooms exactly like a viewport in the app.
class PreviewSceneView: NavigableSceneView {
    /// The preview is hosted out of process, so its drags arrive as forwarded events; accumulate their
    /// deltas rather than relying on window-server mouse deltas.
    override var lockedDragCursorMode: MouseTracker.CursorMode { .lockedUsingEventDeltas }
}

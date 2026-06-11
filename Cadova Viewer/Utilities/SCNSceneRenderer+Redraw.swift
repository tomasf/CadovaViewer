import SceneKit

extension SCNSceneRenderer {
    /// Requests an on-demand redraw. The view renders only when its scene time changes, so
    /// nudging `sceneTime` by a hair marks it dirty without visibly advancing any animation.
    func setNeedsRedraw() {
        sceneTime += 0.00001
    }
}

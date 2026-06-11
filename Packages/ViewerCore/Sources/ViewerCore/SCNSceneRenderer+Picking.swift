import SceneKit

extension SCNSceneRenderer {
    /// The point where the ray through `point` (in view coordinates) crosses the world z = 0 plane.
    public func xyPlanePoint(forViewPoint point: CGPoint) -> SCNVector3 {
        let rayStart = unprojectPoint(SCNVector3(point.x, point.y, 0))
        let rayEnd = unprojectPoint(SCNVector3(point.x, point.y, 1))

        let t = -rayStart.z / (rayEnd.z - rayStart.z)
        return SCNVector3(
            rayStart.x + t * (rayEnd.x - rayStart.x),
            rayStart.y + t * (rayEnd.y - rayStart.y),
            0
        )
    }
}

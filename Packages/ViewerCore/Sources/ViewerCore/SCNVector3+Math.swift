import SceneKit

extension SCNVector3: @retroactive Equatable {
    public static func == (lhs: SCNVector3, rhs: SCNVector3) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y && lhs.z == rhs.z
    }

    public func distance(from other: SCNVector3) -> Double {
        sqrt((x - other.x).magnitudeSquared + (y - other.y).magnitudeSquared + (z - other.z).magnitudeSquared)
    }

    /// The point diametrically opposite this one through `center`: the two are equidistant from
    /// `center` in opposite directions.
    public func mirrored(about center: SCNVector3) -> SCNVector3 {
        SCNVector3(2 * center.x - x, 2 * center.y - y, 2 * center.z - z)
    }
}

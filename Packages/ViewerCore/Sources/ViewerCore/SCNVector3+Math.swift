import SceneKit

extension SCNVector3: @retroactive Equatable {
    public static func == (lhs: SCNVector3, rhs: SCNVector3) -> Bool {
        lhs.x == rhs.x && lhs.y == rhs.y && lhs.z == rhs.z
    }

    public func distance(from other: SCNVector3) -> Double {
        sqrt((x - other.x).magnitudeSquared + (y - other.y).magnitudeSquared + (z - other.z).magnitudeSquared)
    }
}

import SceneKit

extension SCNVector3 {
    /// A `Codable` representation of a 3-vector, used to persist measurement points in restorable state.
    struct CodingWrapper: Codable {
        let x, y, z: Double

        init(_ v: SCNVector3) {
            x = Double(v.x); y = Double(v.y); z = Double(v.z)
        }

        var scnVector3: SCNVector3 { SCNVector3(x, y, z) }
    }
}

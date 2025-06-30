import Foundation
import ThreeMF
import SceneKit

extension ThreeMF.Matrix3D {
    var scnMatrix: SCNMatrix4 {
        let v = values
        return SCNMatrix4(
            m11: v[0][0], m12: v[0][1], m13: v[0][2], m14: 0,
            m21: v[1][0], m22: v[1][1], m23: v[1][2], m24: 0,
            m31: v[2][0], m32: v[2][1], m33: v[2][2], m34: 0,
            m41: v[3][0], m42: v[3][1], m43: v[3][2], m44: 1
        )
    }
}

extension ThreeMF.Mesh.Vertex {
    var scnVector3: SCNVector3 {
        .init(x, y, z)
    }

    var simd: SIMD3<Double> {
        .init(x, y, z)
    }
}

extension ThreeMF.Item {
    var scnTransform: SCNMatrix4 {
        transform?.scnMatrix ?? SCNMatrix4Identity
    }
}

extension ThreeMF.Component {
    var scnTransform: SCNMatrix4 {
        transform?.scnMatrix ?? SCNMatrix4Identity
    }
}

import Foundation
import SceneKit

infix operator ≈: ComparisonPrecedence

protocol ApproximatelyEquatable {
    func equals(_ other: Self, within tolerance: Double) -> Bool
}

extension ApproximatelyEquatable {
    static func ≈(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.equals(rhs, within: 1e-6)
    }
}

extension Double: ApproximatelyEquatable {
    func equals(_ other: Self, within tolerance: Double) -> Bool {
        Swift.abs(self - other) < tolerance
    }
}

extension CGFloat: ApproximatelyEquatable {
    func equals(_ other: Self, within tolerance: Double) -> Bool {
        Swift.abs(self - other) < tolerance
    }
}

extension Array: ApproximatelyEquatable where Element: ApproximatelyEquatable {
    func equals(_ other: Self, within tolerance: Double) -> Bool {
        count == other.count
        && indices.allSatisfy { self[$0].equals(other[$0], within: tolerance) }
    }
}

extension SCNVector3: ApproximatelyEquatable {
    func equals(_ other: Self, within tolerance: Double) -> Bool {
        x.equals(other.x, within: tolerance)
        && y.equals(other.y, within: tolerance)
        && z.equals(other.z, within: tolerance)
    }
}

extension SCNMatrix4: ApproximatelyEquatable {
    func equals(_ other: Self, within tolerance: Double) -> Bool {
        let lhs = [m11, m12, m13, m14, m21, m22, m23, m24,
                   m31, m32, m33, m34, m41, m42, m43, m44]
        let rhs = [other.m11, other.m12, other.m13, other.m14,
                   other.m21, other.m22, other.m23, other.m24,
                   other.m31, other.m32, other.m33, other.m34,
                   other.m41, other.m42, other.m43, other.m44]
        return lhs.equals(rhs, within: tolerance)
    }
}

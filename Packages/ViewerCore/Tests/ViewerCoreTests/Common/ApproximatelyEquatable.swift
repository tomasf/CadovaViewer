import Foundation
import SceneKit
@testable import ViewerCore

infix operator ≈: ComparisonPrecedence

protocol ApproximatelyEquatable {
    func equals(_ other: Self, within tolerance: Double) -> Bool
}

extension ApproximatelyEquatable {
    static func ≈(_ lhs: Self, _ rhs: Self) -> Bool {
        lhs.equals(rhs, within: 1e-3)
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

extension Optional: ApproximatelyEquatable where Wrapped: ApproximatelyEquatable {
    func equals(_ other: Self, within tolerance: Double) -> Bool {
        switch (self, other) {
        case (.none, .none): true
        case (.none, .some), (.some, .none): false
        case (.some(let a), .some(let b)): a.equals(b, within: tolerance)
        }
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

extension SCNVector4: ApproximatelyEquatable {
    func equals(_ other: Self, within tolerance: Double) -> Bool {
        x.equals(other.x, within: tolerance)
        && y.equals(other.y, within: tolerance)
        && z.equals(other.z, within: tolerance)
        && w.equals(other.w, within: tolerance)
    }
}

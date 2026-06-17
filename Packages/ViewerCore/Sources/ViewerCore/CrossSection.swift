import Foundation
import simd

/// A per-viewport cutting plane that hides everything on one side so the model's interior is
/// visible, with a filled "cap" drawn on the cut surface.
///
/// The plane is axis-aligned (the initial UI only offers X/Y/Z presets), defined by an `axis`, an
/// `offset` along that axis in world millimetres, and a `flipped` flag choosing which half is kept.
/// `plane()` turns that into the world-space half-space test the shader and cap passes use:
/// a fragment at world position `p` is kept when `dot(p, normal) <= distance`.
public struct CrossSection: Equatable, Sendable {
    public var enabled: Bool
    public var axis: Axis
    /// Position of the plane along `axis`, in world millimetres.
    public var offset: Double
    /// Keep the high side of the axis instead of the low side.
    public var flipped: Bool
    /// Draw the translucent locator quad at the cut plane.
    public var showPlane: Bool

    public init(enabled: Bool = false, axis: Axis = .z, offset: Double = 0, flipped: Bool = false, showPlane: Bool = true) {
        self.enabled = enabled
        self.axis = axis
        self.offset = offset
        self.flipped = flipped
        self.showPlane = showPlane
    }

    public enum Axis: Int, CaseIterable, Sendable {
        case x, y, z

        /// Index into a `SIMD3` for this axis's component.
        public var index: Int { rawValue }

        /// The positive unit vector along this axis.
        public var unit: SIMD3<Double> {
            switch self {
            case .x: SIMD3(1, 0, 0)
            case .y: SIMD3(0, 1, 0)
            case .z: SIMD3(0, 0, 1)
            }
        }

        public var displayName: String {
            switch self {
            case .x: "X"
            case .y: "Y"
            case .z: "Z"
            }
        }
    }

    /// The world-space half-space, as `(normal.xyz, distance)`. Fragments are kept where
    /// `dot(position, normal) <= distance`.
    ///
    /// Keeping the meaning of `offset` fixed (it's always the world coordinate of the plane along
    /// the axis) means a flip negates both the normal and the distance: not flipped keeps
    /// `p[axis] <= offset`; flipped keeps `p[axis] >= offset`.
    public func plane() -> SIMD4<Double> {
        let sign: Double = flipped ? -1 : 1
        let normal = axis.unit * sign
        return SIMD4(normal.x, normal.y, normal.z, sign * offset)
    }

    /// The slider range for `offset`: the model's extent along the axis. Independent of `flipped`.
    public func offsetRange(boxMin: SIMD3<Double>, boxMax: SIMD3<Double>) -> ClosedRange<Double> {
        let lo = boxMin[axis.index]
        let hi = boxMax[axis.index]
        return lo <= hi ? lo...hi : hi...lo
    }
}

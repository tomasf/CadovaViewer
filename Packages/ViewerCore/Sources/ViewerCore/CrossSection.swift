import Foundation
import simd

/// A per-viewport cutting plane that hides everything on one side so the model's interior is
/// visible, with a filled "cap" drawn on the cut surface.
///
/// The plane is arbitrary: it passes through `origin` (a world-millimetre point) with a normal given
/// by `orientation` applied to +Z. `plane()` turns that into the world-space half-space the shader and
/// cap use: a fragment at `p` is kept when `dot(p, normal) <= distance`. "Flipping" which half is kept
/// is just negating the normal, i.e. rotating the orientation 180° (`flip()`) — there's no separate
/// flag. A viewport holds an array of these; each is positioned/oriented with the interactive gizmo,
/// or snapped to an axis with the X/Y/Z reset buttons.
public struct CrossSection: Identifiable, Equatable, Sendable {
    public let id: UUID
    /// A point the plane passes through, in world millimetres.
    public var origin: SIMD3<Double>
    /// Rotation taking the reference normal (+Z) to this plane's normal.
    public var orientation: simd_quatd
    /// Whether the cut is applied. A disabled section stays in the list (and can still be edited) but
    /// doesn't clip or cap, so the user can temporarily view the whole model.
    public var enabled: Bool
    /// Index into the shared colour palette, for tinting this section's button and cap hatch.
    public var colorIndex: Int

    public init(id: UUID = UUID(), origin: SIMD3<Double>, orientation: simd_quatd = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), enabled: Bool = true, colorIndex: Int = 0) {
        self.id = id
        self.origin = origin
        self.orientation = orientation
        self.enabled = enabled
        self.colorIndex = colorIndex
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

    /// The plane's unit normal in world space (the kept half is `dot(p, normal) <= distance`).
    public var normal: SIMD3<Double> {
        orientation.act(SIMD3(0, 0, 1))
    }

    /// Flips which half is kept by negating the normal (a 180° turn about an in-plane axis).
    public mutating func flip() {
        orientation = orientation * simd_quatd(angle: .pi, axis: SIMD3(1, 0, 0))
    }

    /// The world-space half-space as `(normal.xyz, distance)`; kept where `dot(p, normal) <= distance`.
    public func plane() -> SIMD4<Double> {
        let n = normal
        return SIMD4(n.x, n.y, n.z, simd_dot(n, origin))
    }

    /// Whether `point` is on the cut-away (hidden) side, beyond the plane by more than `tolerance`.
    /// Mirrors the clip shader so hit-testing matches what's visible. The small tolerance keeps a cap
    /// — which sits exactly on its own plane (`dot == distance`) — from being rejected by that plane,
    /// while other planes still clip it.
    public func hides(_ point: SIMD3<Double>, tolerance: Double = 1e-4) -> Bool {
        simd_dot(point, normal) > simd_dot(normal, origin) + tolerance
    }

    /// The orientation whose +Z maps onto the given world axis (for the X/Y/Z reset shortcuts).
    public static func orientation(for axis: Axis) -> simd_quatd {
        simd_quatd(from: SIMD3(0, 0, 1), to: axis.unit)
    }

    /// A new section flat along `axis` (normal = that axis) through `origin`.
    public static func axisAligned(_ axis: Axis, origin: SIMD3<Double>, colorIndex: Int = 0) -> CrossSection {
        CrossSection(origin: origin, orientation: orientation(for: axis), colorIndex: colorIndex)
    }

    public static func == (lhs: CrossSection, rhs: CrossSection) -> Bool {
        lhs.id == rhs.id
            && lhs.origin == rhs.origin
            && lhs.orientation.vector == rhs.orientation.vector
            && lhs.enabled == rhs.enabled
            && lhs.colorIndex == rhs.colorIndex
    }
}

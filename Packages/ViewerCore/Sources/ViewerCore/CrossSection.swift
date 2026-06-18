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
public struct CrossSection: Identifiable, Equatable, Sendable, Codable {
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

    /// Whether the cut's normal already points along this axis's positive direction (so aligning to it
    /// would do nothing).
    public func isAligned(to axis: Axis) -> Bool {
        simd_dot(normal, axis.unit) > 0.9999
    }

    /// Whether the cut's normal already lies on a signed world axis (so snapping to the nearest axis
    /// would do nothing).
    public var isAxisAligned: Bool {
        Axis.allCases.contains { abs(simd_dot(normal, $0.unit)) > 0.9999 }
    }

    /// Snaps the plane's normal to the nearest signed world axis (±X/±Y/±Z), keeping `origin` and the
    /// half that's currently kept. Useful after free rotation with the gizmo to get a clean
    /// axis-aligned cut.
    public mutating func snapToNearestAxis() {
        let n = normal
        var best = SIMD3<Double>(0, 0, 1)
        var bestDot = -Double.infinity
        for axis in Axis.allCases {
            for sign in [1.0, -1.0] {
                let direction = axis.unit * sign
                let dot = simd_dot(n, direction)
                if dot > bestDot { bestDot = dot; best = direction }
            }
        }
        let z = SIMD3<Double>(0, 0, 1)
        // `simd_quatd(from:to:)` is undefined for antiparallel vectors, so turn 180° explicitly there.
        orientation = simd_dot(best, z) < -0.5
            ? simd_quatd(angle: .pi, axis: SIMD3(1, 0, 0))
            : simd_quatd(from: z, to: best)
    }

    /// A new section flat along `axis` (normal = that axis) through `origin`.
    public static func axisAligned(_ axis: Axis, origin: SIMD3<Double>, colorIndex: Int = 0) -> CrossSection {
        CrossSection(origin: origin, orientation: orientation(for: axis), colorIndex: colorIndex)
    }

    // simd_quatd isn't Codable, so encode the orientation as its vector (x, y, z, w).
    private enum CodingKeys: String, CodingKey {
        case id, origin, orientation, enabled, colorIndex
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let vector = try container.decode(SIMD4<Double>.self, forKey: .orientation)
        self.init(
            id: try container.decode(UUID.self, forKey: .id),
            origin: try container.decode(SIMD3<Double>.self, forKey: .origin),
            orientation: simd_quatd(vector: vector),
            enabled: try container.decode(Bool.self, forKey: .enabled),
            colorIndex: try container.decode(Int.self, forKey: .colorIndex)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(origin, forKey: .origin)
        try container.encode(orientation.vector, forKey: .orientation)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(colorIndex, forKey: .colorIndex)
    }

    public static func == (lhs: CrossSection, rhs: CrossSection) -> Bool {
        lhs.id == rhs.id
            && lhs.origin == rhs.origin
            && lhs.orientation.vector == rhs.orientation.vector
            && lhs.enabled == rhs.enabled
            && lhs.colorIndex == rhs.colorIndex
    }
}

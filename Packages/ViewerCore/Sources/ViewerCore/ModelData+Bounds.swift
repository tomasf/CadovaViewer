import SceneKit
import simd

extension ModelData {
    /// An axis-aligned box in world space, in millimetres.
    public struct BoundingBox: Sendable, Equatable {
        public var min: SIMD3<Double>
        public var max: SIMD3<Double>

        public init(min: SIMD3<Double>, max: SIMD3<Double>) {
            self.min = min
            self.max = max
        }

        public var size: SIMD3<Double> { max - min }

        /// The smallest box containing both.
        public func union(_ other: BoundingBox) -> BoundingBox {
            BoundingBox(min: simd_min(min, other.min), max: simd_max(max, other.max))
        }

        /// The union of the given parts' world bounding boxes, or nil if none has geometry.
        public static func union(of parts: some Sequence<Part>) -> BoundingBox? {
            parts.compactMap(\.worldBoundingBox).reduce(nil) { $0?.union($1) ?? $1 }
        }
    }
}

extension ModelData.Part {
    /// The part's bounds in world space (millimetres, after the build transform and unit scale), or
    /// nil if it has no geometry. Reads `nodes.container`, which stays parented into
    /// `ModelData.rootNode`, so no viewport is involved.
    public var worldBoundingBox: ModelData.BoundingBox? {
        let box = nodes.container.worldBoundingBox()
        let (min, max) = (SIMD3<Double>(box.min), SIMD3<Double>(box.max))
        guard min != max else { return nil }
        return .init(min: min, max: max)
    }
}

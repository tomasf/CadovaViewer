import SwiftUI
import SceneKit
import ViewerCore

/// The "Get Info" sheet for one or more selected sidebar parts — the part-scoped counterpart to
/// `InformationView`, without file size or document metadata, plus a semantic row. The name row only
/// makes sense for a single part, so it's dropped when multiple parts are selected; the geometry
/// stats and semantic combine across all selected parts.
struct PartInformationView: View {
    let model: Model

    private var singlePart: ModelData.Part? {
        model.parts.count == 1 ? model.parts.first : nil
    }

    private var statistics: ModelData.Statistics {
        .init(model.parts.map(\.statistics))
    }

    private var semanticDescription: String {
        let semantics = Set(model.parts.map(\.semantic))
        if let only = semantics.first, semantics.count == 1 {
            return only.displayName
        }
        return "Mixed"
    }

    var body: some View {
        InfoSheet {
            Section {
                if let singlePart {
                    LabeledContent("Name", value: singlePart.name)
                }
                LabeledContent("Semantic", value: semanticDescription)
            }

            GeometryStatsSection(
                dimensions: Self.combinedWorldBoundingBoxSize(of: model.parts),
                statistics: statistics
            )
        }
    }

    /// The union, in world space, of the parts' container nodes' bounding boxes. Transforms all 8
    /// local-space corners of each box (not just min/max) since a rotated box's world-space extent
    /// isn't just its transformed corner points. Mirrors `ViewportController+View.combinedWorldBoundingBox`,
    /// but reads straight from `Part.nodes.container` — which is permanently parented into
    /// `ModelData.rootNode`, so its world transform is meaningful without any viewport involved.
    private static func combinedWorldBoundingBoxSize(of parts: [ModelData.Part]) -> SIMD3<Double>? {
        var result: (min: SIMD3<Double>, max: SIMD3<Double>)?
        for part in parts {
            let node = part.nodes.container
            let (localMin, localMax) = node.boundingBox
            let transform = node.simdWorldTransform
            let corners: [SIMD3<Float>] = [
                SIMD3(Float(localMin.x), Float(localMin.y), Float(localMin.z)),
                SIMD3(Float(localMin.x), Float(localMin.y), Float(localMax.z)),
                SIMD3(Float(localMin.x), Float(localMax.y), Float(localMin.z)),
                SIMD3(Float(localMin.x), Float(localMax.y), Float(localMax.z)),
                SIMD3(Float(localMax.x), Float(localMin.y), Float(localMin.z)),
                SIMD3(Float(localMax.x), Float(localMin.y), Float(localMax.z)),
                SIMD3(Float(localMax.x), Float(localMax.y), Float(localMin.z)),
                SIMD3(Float(localMax.x), Float(localMax.y), Float(localMax.z))
            ]
            for corner in corners {
                let world = SIMD3<Double>((transform * SIMD4<Float>(corner, 1)).xyz)
                if result == nil {
                    result = (world, world)
                } else {
                    result!.min = simd_min(result!.min, world)
                    result!.max = simd_max(result!.max, world)
                }
            }
        }
        guard let box = result else { return nil }
        return box.max - box.min
    }

    struct Model: Identifiable {
        let parts: [ModelData.Part]
        let id = UUID()
    }
}

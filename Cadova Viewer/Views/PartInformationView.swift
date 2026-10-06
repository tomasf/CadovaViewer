import SwiftUI
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
                dimensions: ModelData.BoundingBox.union(of: model.parts)?.size,
                statistics: statistics
            )
        }
    }

    struct Model: Identifiable {
        let parts: [ModelData.Part]
        let id = UUID()
    }
}

import SwiftUI
import ViewerCore

/// Shared chrome for the "Get Info" sheets (document-wide and per-part): a grouped `Form` plus a
/// Close button, so the two sheets only need to supply their own rows.
struct InfoSheet<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack {
            Form {
                content
            }
            .formStyle(.grouped)

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .padding(.bottom)
        }
    }
}

/// Number formatting shared by the info sheets' geometry rows.
enum InfoFormatting {
    static func dimensions(_ size: SIMD3<Double>) -> String {
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
        return "\(size.x.formatted(format)) × \(size.y.formatted(format)) × \(size.z.formatted(format)) mm"
    }

    static func volume(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0)))) mm³"
    }

    static func surfaceArea(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(0)))) mm²"
    }
}

/// The geometry-statistics rows shared by the document and part info sheets. `dimensions` and
/// `partCount` are omitted (nil) where they don't apply to the sheet showing this section.
struct GeometryStatsSection: View {
    var dimensions: SIMD3<Double>?
    var partCount: Int?
    var statistics: ModelData.Statistics

    var body: some View {
        Section {
            if let dimensions {
                LabeledContent("Dimensions") { Text(InfoFormatting.dimensions(dimensions)) }
            }
            LabeledContent("Volume") { Text(InfoFormatting.volume(statistics.volume)) }
            LabeledContent("Surface Area") { Text(InfoFormatting.surfaceArea(statistics.surfaceArea)) }
            if let partCount {
                LabeledContent("Parts") { Text("\(partCount)") }
            }
            LabeledContent("Vertices") { Text("\(statistics.vertexCount)") }
            LabeledContent("Triangles") { Text("\(statistics.triangleCount)") }
        }
    }
}

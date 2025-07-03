import Cocoa
import SwiftUI
import SceneKit
import ThreeMF

struct InformationView: View {
    let model: Model
    @Environment(\.dismiss) var dismiss

    var body: some View {
        VStack {
            Form {
                Section {
                    LabeledContent("Name", value: model.document.displayName)
                    LabeledContent("File Size", value: formattedFileSize)
                }

                Section {
                    LabeledContent("Vertices") { Text("\(model.modelData.statistics.vertexCount)") }
                    LabeledContent("Triangles") { Text("\(model.modelData.statistics.triangleCount)") }
                }

                if !sortedMetadataGroups.isEmpty {
                    Section() {
                        ForEach(sortedMetadataGroups, id: \.0) { group, items in
                            LabeledContent(label(for: group)) {
                                Text(items.map(\.value).joined(separator: "\n"))
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Button("Close") {
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .padding(.bottom)
        }
    }

    var formattedFileSize: String {
        guard let url = model.document.fileURL,
              let size = try? FileManager().attributesOfItem(atPath: url.path())[.size] as? Int else {
            return ""
        }
        return ByteCountFormatter().string(fromByteCount: Int64(size))
    }

    var sortedMetadataGroups: [(Metadata.Name, [Metadata])] {
        Dictionary(grouping: model.modelData.metadata, by: \.name).sorted { $0.key < $1.key }
    }

    func label(for name: Metadata.Name) -> String {
        switch name {
        case .title: "Title"
        case .designer: "Designer"
        case .description: "Description"
        case .copyright: "Copyright"
        case .licenseTerms: "License Terms"
        case .rating: "Rating"
        case .creationDate: "Creation Date"
        case .modificationDate: "Modification Date"
        case .application: "Application"
        case .custom(let string): string
        }
    }

    struct Model: Identifiable {
        let document: Document
        let modelData: ModelData

        var id: URL { document.fileURL! }
    }
}

fileprivate extension Metadata.Name {
    static var standardOrder: [Metadata.Name] {
        [.title, .designer, .description, .copyright, .licenseTerms, .rating, .creationDate, .modificationDate, .application]
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.custom(let a), .custom(let b)): a < b
        case (.custom, _): false
        case (_, .custom): true
        default: (Self.standardOrder.firstIndex(of: lhs) ?? 0) < (Self.standardOrder.firstIndex(of: rhs) ?? 0)
        }
    }
}

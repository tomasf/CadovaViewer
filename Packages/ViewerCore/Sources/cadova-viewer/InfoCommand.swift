import ArgumentParser
import Foundation
import ViewerCore

/// `cadova-viewer info`: reports a model's dimensions, geometry statistics, parts and metadata.
struct InfoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "info",
        abstract: "Reports a 3MF model's dimensions, volume, surface area, parts and metadata.",
        discussion: "Lengths are in millimetres, areas in mm² and volumes in mm³. Volume is only meaningful for watertight parts."
    )

    enum Format: String, ExpressibleByArgument, CaseIterable {
        case json
        case text
    }

    @Argument(help: "Path to the input .3mf file.")
    var input: String

    @Option(help: "Output format: json or text.")
    var format: Format = .json

    @OptionGroup var partSelection: PartSelection

    func run() async throws {
        let inputURL = URL(fileURLWithPath: input)
        let modelData = try ModelData(url: inputURL, includeEdges: false)
        let parts = try partSelection.selectedParts(in: modelData)
        let report = ModelReport(file: inputURL.lastPathComponent, parts: parts, metadata: modelData.metadata)

        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        case .text:
            print(report.textDescription)
        }
    }
}

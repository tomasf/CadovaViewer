import ArgumentParser
import ViewerCore

/// `--include-part`/`--exclude-part`, shared by the subcommands that work on a subset of a model's parts.
struct PartSelection: ParsableArguments {
    @Option(name: .customLong("include-part"), help: ArgumentHelp("Use only this part, by name or part number. Repeat to include several parts.", valueName: "part"))
    var includedParts: [String] = []

    @Option(name: .customLong("exclude-part"), help: ArgumentHelp("Leave out this part, by name or part number. Repeat to exclude several parts.", valueName: "part"))
    var excludedParts: [String] = []

    func validate() throws {
        if !includedParts.isEmpty, !excludedParts.isEmpty {
            throw ValidationError("--include-part and --exclude-part can't be combined.")
        }
    }

    /// The parts this selection keeps, in model order. Each value matches every part with that name
    /// or part number; a value matching nothing, or excluding every part, is an error.
    func selectedParts(in modelData: ModelData) throws -> [ModelData.Part] {
        let requested = includedParts.isEmpty ? excludedParts : includedParts
        guard !requested.isEmpty else { return modelData.parts }

        var matched: Set<ModelData.Part.ID> = []
        for value in requested {
            let matches = modelData.parts.filter { $0.name == value || $0.partNumber == value }
            guard !matches.isEmpty else {
                let available = modelData.parts.map { "'\($0.name)'" }.joined(separator: ", ")
                throw ValidationError("No part named '\(value)'. Parts in this model: \(available).")
            }
            matched.formUnion(matches.map(\.id))
        }

        let selected = modelData.parts.filter { matched.contains($0.id) != includedParts.isEmpty }
        guard !selected.isEmpty else {
            throw ValidationError("--exclude-part leaves no parts.")
        }
        return selected
    }
}

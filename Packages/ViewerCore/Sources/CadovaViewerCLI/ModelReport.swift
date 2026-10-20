import Foundation
import ThreeMF
import ViewerCore

/// What `cadova-viewer info` reports: the selected parts' combined geometry, each part's own, and the
/// model's metadata. Encoded as JSON with sorted keys, so output is stable; `textDescription` is the
/// human-readable form. Lengths are in millimetres, rounded to `precision` decimals.
struct ModelReport: Encodable {
    let file: String
    let boundingBox: Box?
    let statistics: Statistics
    let partCount: Int
    let metadata: [MetadataEntry]
    let parts: [Part]

    /// Decimal places kept: micrometre resolution, which is beyond what the Float geometry carries.
    static let precision = 3

    init(file: String, parts: [ModelData.Part], metadata: [ThreeMF.Metadata]) {
        self.file = file
        boundingBox = ModelData.BoundingBox.union(of: parts).map(Box.init)
        statistics = Statistics(.init(parts.map(\.statistics)))
        partCount = parts.count
        self.metadata = metadata.map(MetadataEntry.init)
        self.parts = parts.map(Part.init)
    }

    struct Box: Encodable {
        let min: [Double]
        let max: [Double]
        let size: [Double]

        init(_ box: ModelData.BoundingBox) {
            min = ModelReport.rounded(box.min)
            max = ModelReport.rounded(box.max)
            size = ModelReport.rounded(box.size)
        }
    }

    struct Statistics: Encodable {
        let volume: Double
        let surfaceArea: Double
        let triangleCount: Int
        let vertexCount: Int

        init(_ statistics: ModelData.Statistics) {
            volume = ModelReport.rounded(statistics.volume)
            surfaceArea = ModelReport.rounded(statistics.surfaceArea)
            triangleCount = statistics.triangleCount
            vertexCount = statistics.vertexCount
        }
    }

    struct Part: Encodable {
        let name: String
        let partNumber: String?
        let semantic: String
        let boundingBox: Box?
        let statistics: Statistics

        init(_ part: ModelData.Part) {
            name = part.name
            partNumber = part.partNumber
            semantic = part.semantic.rawValue
            boundingBox = part.worldBoundingBox.map(Box.init)
            statistics = Statistics(part.statistics)
        }
    }

    struct MetadataEntry: Encodable {
        let name: String
        let value: String

        init(_ metadata: ThreeMF.Metadata) {
            name = metadata.name.identifier
            value = metadata.value
        }
    }

    static func rounded(_ value: Double) -> Double {
        let scale = pow(10, Double(precision))
        return (value * scale).rounded() / scale
    }

    static func rounded(_ vector: SIMD3<Double>) -> [Double] {
        [rounded(vector.x), rounded(vector.y), rounded(vector.z)]
    }
}

// MARK: - Text output

extension ModelReport {
    var textDescription: String {
        var lines = [file]
        lines += Self.geometryLines(boundingBox: boundingBox, statistics: statistics)
        lines.append(Self.row("Parts", "\(partCount)"))

        if !metadata.isEmpty {
            lines.append("")
            lines.append("Metadata")
            lines += metadata.map { Self.row($0.name, $0.value) }
        }

        for part in parts {
            lines.append("")
            var heading = "Part: \(part.name)"
            if let partNumber = part.partNumber {
                heading += " (part number \(partNumber))"
            }
            lines.append(heading)
            lines.append(Self.row("Semantic", part.semantic))
            lines += Self.geometryLines(boundingBox: part.boundingBox, statistics: part.statistics)
        }
        return lines.joined(separator: "\n")
    }

    private static func geometryLines(boundingBox: Box?, statistics: Statistics) -> [String] {
        var lines: [String] = []
        if let boundingBox {
            lines.append(row("Dimensions", "\(format(boundingBox.size, separator: " × ")) mm"))
            lines.append(row("Bounds", "(\(format(boundingBox.min, separator: ", "))) to (\(format(boundingBox.max, separator: ", ")))"))
        }
        lines.append(row("Volume", "\(format(statistics.volume)) mm³"))
        lines.append(row("Surface area", "\(format(statistics.surfaceArea)) mm²"))
        lines.append(row("Triangles", "\(statistics.triangleCount)"))
        lines.append(row("Vertices", "\(statistics.vertexCount)"))
        return lines
    }

    private static func row(_ label: String, _ value: String) -> String {
        "  " + (label + ":").padding(toLength: 15, withPad: " ", startingAt: 0) + value
    }

    /// Fixed POSIX formatting, so output doesn't change with the user's locale.
    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...precision)).grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }

    private static func format(_ values: [Double], separator: String) -> String {
        values.map(format).joined(separator: separator)
    }
}

extension ThreeMF.Metadata.Name {
    /// The name as written in the 3MF file (e.g. `LicenseTerms`).
    var identifier: String {
        switch self {
        case .title: "Title"
        case .designer: "Designer"
        case .description: "Description"
        case .copyright: "Copyright"
        case .licenseTerms: "LicenseTerms"
        case .rating: "Rating"
        case .creationDate: "CreationDate"
        case .modificationDate: "ModificationDate"
        case .application: "Application"
        case .custom(let name): name
        }
    }
}

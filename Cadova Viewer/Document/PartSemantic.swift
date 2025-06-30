import Foundation
import Nodal
import ThreeMF

enum PartSemantic: String, Hashable, Sendable, Codable {
    /// A regular printable part, typically rendered as opaque and included in the physical output.
    case solid

    /// A background or reference part used for spatial context. These parts are included in the model for visualization,
    /// but are not intended to be printed or interact with the printable geometry.
    case context

    /// A visual-only part used for display, guidance, or context. These are not intended for printing.
    case visual
}

fileprivate extension ExpandedName {
    static let printable = ExpandedName(namespaceName: nil, localName: "printable")
    static let semantic = CadovaNamespace.semantic
}

fileprivate struct CadovaNamespace {
    static let uri = "https://cadova.org/3mf"
    static let semantic = ExpandedName(namespaceName: uri, localName: "semantic")
}

fileprivate extension PartSemantic {
    init?(xmlAttributeValue value: String) {
        self.init(rawValue: value)
    }

    var xmlAttributeValue: String { rawValue }
}

extension ThreeMF.Item {
    var semantic: PartSemantic {
        if let attribute = customAttributes[.semantic], let parsed = PartSemantic(xmlAttributeValue: attribute) {
            return parsed
        } else {
            return .solid
        }
    }
}

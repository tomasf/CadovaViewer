import Foundation
import SceneKit
import ViewerCore

/// Per-viewport view state. Each viewport in a document has its own; document-wide options that
/// act on the shared model geometry (smooth shading, edge visibility) live in `DocumentViewOptions`.
struct ViewOptions: Codable {
    var showGrid = true
    var showOrigin = true
    var showCoordinateSystemIndicator = true
    var cameraTransform: SCNMatrix4 = SCNMatrix4Identity
    var hiddenPartIDs: Set<ModelData.Part.ID> = []

    enum CodingKeys: String, CodingKey {
        case showGrid
        case showOrigin
        case showCoordinateSystemIndicator
        case cameraTransform
        case hiddenPartIDs
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showGrid = try container.decode(Bool.self, forKey: .showGrid)
        showOrigin = try container.decode(Bool.self, forKey: .showOrigin)
        showCoordinateSystemIndicator = try container.decode(Bool.self, forKey: .showCoordinateSystemIndicator)
        cameraTransform = try container.decode(SCNMatrix4.CodingWrapper.self, forKey: .cameraTransform).scnMatrix4
        hiddenPartIDs = try container.decode(Set<ModelData.Part.ID>.self, forKey: .hiddenPartIDs)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showGrid, forKey: .showGrid)
        try container.encode(showOrigin, forKey: .showOrigin)
        try container.encode(showCoordinateSystemIndicator, forKey: .showCoordinateSystemIndicator)
        try container.encode(SCNMatrix4.CodingWrapper(cameraTransform), forKey: .cameraTransform)
        try container.encode(hiddenPartIDs, forKey: .hiddenPartIDs)
    }
}

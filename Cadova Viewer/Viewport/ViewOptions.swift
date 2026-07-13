import Foundation
import SceneKit
import ViewerCore

/// Per-viewport view state. Each viewport in a document has its own, including smooth shading, edge
/// visibility, and materials-enabled — the per-viewport model clone (`ViewportModelInstance`) gives
/// each viewport its own edge-line nodes, flat/smooth geometry copies, and material copies, so these
/// can differ per viewport rather than being shared across the document.
struct ViewOptions: Codable {
    var showGrid = true
    var showOrigin = true
    var showCoordinateSystemIndicator = true
    var cameraTransform: SCNMatrix4 = SCNMatrix4Identity
    var hiddenPartIDs: Set<ModelData.Part.ID> = []
    var smoothShading = false
    var edgeVisibility: EdgeVisibility = .sharp
    var materialsEnabled = true

    enum EdgeVisibility: String, Codable {
        case none
        case sharp
        case all
    }

    enum CodingKeys: String, CodingKey {
        case showGrid
        case showOrigin
        case showCoordinateSystemIndicator
        case cameraTransform
        case hiddenPartIDs
        case smoothShading
        case edgeVisibility
        case materialsEnabled
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showGrid = try container.decode(Bool.self, forKey: .showGrid)
        showOrigin = try container.decode(Bool.self, forKey: .showOrigin)
        showCoordinateSystemIndicator = try container.decode(Bool.self, forKey: .showCoordinateSystemIndicator)
        cameraTransform = try container.decode(SCNMatrix4.CodingWrapper.self, forKey: .cameraTransform).scnMatrix4
        hiddenPartIDs = try container.decode(Set<ModelData.Part.ID>.self, forKey: .hiddenPartIDs)
        // Older persisted blobs predate these fields (smoothShading/edgeVisibility used to be a
        // separate document-wide preference; materialsEnabled is simply new) — default them rather
        // than failing to decode.
        smoothShading = try container.decodeIfPresent(Bool.self, forKey: .smoothShading) ?? false
        edgeVisibility = try container.decodeIfPresent(EdgeVisibility.self, forKey: .edgeVisibility) ?? .sharp
        materialsEnabled = try container.decodeIfPresent(Bool.self, forKey: .materialsEnabled) ?? true
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showGrid, forKey: .showGrid)
        try container.encode(showOrigin, forKey: .showOrigin)
        try container.encode(showCoordinateSystemIndicator, forKey: .showCoordinateSystemIndicator)
        try container.encode(SCNMatrix4.CodingWrapper(cameraTransform), forKey: .cameraTransform)
        try container.encode(hiddenPartIDs, forKey: .hiddenPartIDs)
        try container.encode(smoothShading, forKey: .smoothShading)
        try container.encode(edgeVisibility, forKey: .edgeVisibility)
        try container.encode(materialsEnabled, forKey: .materialsEnabled)
    }
}

import Foundation
import SceneKit

struct ViewOptions: Codable {
    var showGrid = true
    var showOrigin = true
    var showCoordinateSystemIndicator = true
    var edgeVisibility: EdgeVisibility = .sharp
    var cameraTransform: SCNMatrix4 = SCNMatrix4Identity
    var hiddenPartIDs: Set<ModelData.Part.ID> = []

    enum CodingKeys: String, CodingKey {
        case showGrid
        case showOrigin
        case showCoordinateSystemIndicator
        case cameraTransform
        case edgeVisibility
        case hiddenPartIDs
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showGrid = try container.decode(Bool.self, forKey: .showGrid)
        showOrigin = try container.decode(Bool.self, forKey: .showOrigin)
        showCoordinateSystemIndicator = try container.decode(Bool.self, forKey: .showCoordinateSystemIndicator)
        cameraTransform = try container.decode(SCNMatrix4.CodingWrapper.self, forKey: .cameraTransform).scnMatrix4
        edgeVisibility = (try? container.decode(EdgeVisibility.self, forKey: .edgeVisibility)) ?? .sharp
        hiddenPartIDs = try container.decode(Set<ModelData.Part.ID>.self, forKey: .hiddenPartIDs)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(showGrid, forKey: .showGrid)
        try container.encode(showOrigin, forKey: .showOrigin)
        try container.encode(showCoordinateSystemIndicator, forKey: .showCoordinateSystemIndicator)
        try container.encode(SCNMatrix4.CodingWrapper(cameraTransform), forKey: .cameraTransform)
        try container.encode(edgeVisibility, forKey: .edgeVisibility)
        try container.encode(hiddenPartIDs, forKey: .hiddenPartIDs)
    }

    enum EdgeVisibility: String, Codable {
        case none
        case sharp
        case all
    }
}

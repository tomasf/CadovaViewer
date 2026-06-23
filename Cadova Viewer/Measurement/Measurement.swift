import Foundation
import SceneKit
import ViewerCore

enum InteractionMode: Hashable {
    case view
    case measure
}

struct Measurement: Identifiable {
    enum Phase: String, Codable {
        case coordinate        // single point, only its coordinates are known
        case lengthInProgress  // start is fixed, end follows the cursor (may be nil)
        case complete          // both endpoints fixed
    }

    let id = UUID()
    let colorIndex: Int
    var start: SCNVector3
    var end: SCNVector3?
    var phase: Phase

    var delta: SCNVector3? {
        guard let end else { return nil }
        return SCNVector3(end.x - start.x, end.y - start.y, end.z - start.z)
    }

    var length: Double? {
        guard let end else { return nil }
        return end.distance(from: start)
    }
}

// Persisted in the document's restorable state. `id` isn't encoded — a fresh one is fine on restore
// (it's only used transiently, e.g. for the sidebar highlight). `SCNVector3` isn't `Codable`, so the
// points go through `SCNVector3.CodingWrapper`.
extension Measurement: Codable {
    enum CodingKeys: String, CodingKey { case colorIndex, start, end, phase }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        colorIndex = try container.decode(Int.self, forKey: .colorIndex)
        start = try container.decode(SCNVector3.CodingWrapper.self, forKey: .start).scnVector3
        end = try container.decodeIfPresent(SCNVector3.CodingWrapper.self, forKey: .end)?.scnVector3
        phase = try container.decode(Phase.self, forKey: .phase)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(colorIndex, forKey: .colorIndex)
        try container.encode(SCNVector3.CodingWrapper(start), forKey: .start)
        try container.encodeIfPresent(end.map(SCNVector3.CodingWrapper.init), forKey: .end)
        try container.encode(phase, forKey: .phase)
    }
}

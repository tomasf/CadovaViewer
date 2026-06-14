import Foundation
import SceneKit
import ViewerCore

enum InteractionMode: Hashable {
    case view
    case measure
}

struct Measurement: Identifiable {
    enum Phase {
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

import Foundation
import SceneKit
import SwiftUI

struct Measurement: Identifiable, Equatable {
    let id: Int
    var fromPoint: SCNVector3
    var toPoint: SCNVector3?

    init(id: Int, fromPoint: SCNVector3, toPoint: SCNVector3?) {
        self.id = id
        self.fromPoint = fromPoint
        self.toPoint = toPoint
    }

    init(id: Int, fromPoint: SCNVector3) {
        self.id = id
        self.fromPoint = fromPoint
        self.toPoint = nil
    }

    func withToPoint(_ toPoint: SCNVector3) -> Measurement {
        Measurement(id: id, fromPoint: fromPoint, toPoint: toPoint)
    }

    var points: [SCNVector3] {
        if let toPoint {
            [fromPoint, toPoint]
        } else {
            [fromPoint]
        }
    }

    var distanceMeasurement: DistanceMeasurement? {
        guard let toPoint else { return nil }
        return DistanceMeasurement(fromPoint: fromPoint, toPoint: toPoint)
    }
}

extension Measurement {
    private static let colors: [Color] = [.blue, .green, .yellow, .orange, .red]
    var color: Color {
        Self.colors[id % Self.colors.count]
    }
}

struct DistanceMeasurement {
    let fromPoint: SCNVector3
    let toPoint: SCNVector3
}

extension DistanceMeasurement {
    var distance: Double { toPoint.distance(from: fromPoint) }
    var deltaX: Double { toPoint.x - fromPoint.x }
    var deltaY: Double { toPoint.y - fromPoint.y }
    var deltaZ: Double { toPoint.z - fromPoint.z }
}

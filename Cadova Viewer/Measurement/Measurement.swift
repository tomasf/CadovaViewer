import Foundation
import SceneKit
import AppKit
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

    var color: NSColor {
        Self.color(forIndex: colorIndex)
    }

    var delta: SCNVector3? {
        guard let end else { return nil }
        return SCNVector3(end.x - start.x, end.y - start.y, end.z - start.z)
    }

    var length: Double? {
        guard let end else { return nil }
        return end.distance(from: start)
    }

    // MARK: - Colors

    static let palette: [NSColor] = [
        NSColor(red: 1.00, green: 0.80, blue: 0.00, alpha: 1), // amber
        NSColor(red: 0.20, green: 0.78, blue: 0.95, alpha: 1), // cyan
        NSColor(red: 1.00, green: 0.40, blue: 0.40, alpha: 1), // coral
        NSColor(red: 0.50, green: 0.90, blue: 0.45, alpha: 1), // green
        NSColor(red: 0.80, green: 0.55, blue: 1.00, alpha: 1), // purple
        NSColor(red: 1.00, green: 0.60, blue: 0.20, alpha: 1), // orange
        NSColor(red: 0.45, green: 0.70, blue: 1.00, alpha: 1), // blue
        NSColor(red: 1.00, green: 0.50, blue: 0.80, alpha: 1), // pink
    ]

    static func color(forIndex index: Int) -> NSColor {
        palette[index % palette.count]
    }
}

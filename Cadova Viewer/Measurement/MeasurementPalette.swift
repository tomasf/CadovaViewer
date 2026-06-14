import AppKit
import SwiftUI

enum MeasurementPalette {
    struct Entry: Equatable {
        let red: Double
        let green: Double
        let blue: Double
        let alpha: Double
    }

    static let entries: [Entry] = [
        Entry(red: 1.00, green: 0.80, blue: 0.00, alpha: 1), // amber
        Entry(red: 0.20, green: 0.78, blue: 0.95, alpha: 1), // cyan
        Entry(red: 1.00, green: 0.40, blue: 0.40, alpha: 1), // coral
        Entry(red: 0.50, green: 0.90, blue: 0.45, alpha: 1), // green
        Entry(red: 0.80, green: 0.55, blue: 1.00, alpha: 1), // purple
        Entry(red: 1.00, green: 0.60, blue: 0.20, alpha: 1), // orange
        Entry(red: 0.45, green: 0.70, blue: 1.00, alpha: 1), // blue
        Entry(red: 1.00, green: 0.50, blue: 0.80, alpha: 1), // pink
    ]

    static func entry(forIndex index: Int) -> Entry {
        entries[index % entries.count]
    }

    static func nsColor(forIndex index: Int) -> NSColor {
        let entry = entry(forIndex: index)
        return NSColor(red: entry.red, green: entry.green, blue: entry.blue, alpha: entry.alpha)
    }

    static func color(forIndex index: Int) -> Color {
        let entry = entry(forIndex: index)
        return Color(red: entry.red, green: entry.green, blue: entry.blue, opacity: entry.alpha)
    }
}

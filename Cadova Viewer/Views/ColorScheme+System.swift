import SwiftUI
import AppKit

extension ColorScheme {
    /// The app's real light/dark appearance, regardless of any `.colorScheme(...)` override in the
    /// SwiftUI environment (e.g. the viewport subtree forces dark). Useful for popovers/overlays that
    /// should follow the system appearance rather than inherit a forced scheme.
    static var system: ColorScheme {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
    }
}

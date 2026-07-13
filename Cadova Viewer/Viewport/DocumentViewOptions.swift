import Foundation

/// Legacy shape of the pre-per-viewport-shading "smooth shading"/"show edges" preference. Kept only
/// to decode old persisted data (`Preferences`'s remembered default, and per-document window-
/// restoration state) — see `Preferences.viewOptions` and `DocumentViewModel.restore(_:)`.
struct LegacyDocumentViewOptions: Codable {
    var smoothShading = false
    var edgeVisibility: ViewOptions.EdgeVisibility = .sharp
}

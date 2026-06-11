import Foundation

/// Document-wide view state shared by every viewport. These options act on the shared model
/// geometry — edge lines are toggled with a global `isHidden` (line geometry ignores category
/// masks) and smooth shading swaps the shared mesh in place — so they can't be per-viewport
/// without duplicating meshes.
struct DocumentViewOptions: Codable {
    var smoothShading = false
    var edgeVisibility: EdgeVisibility = .sharp

    init() {}

    enum EdgeVisibility: String, Codable {
        case none
        case sharp
        case all
    }
}

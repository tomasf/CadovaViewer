import Foundation

/// A binary tree describing how a document's viewports are arranged. A `.leaf` is one viewport
/// (identified by a stable UUID that maps to a `ViewportController`); a `.split` divides its area
/// between two child layouts along an axis. Split-divider ratios are stored separately (keyed by
/// the split's id) so they're easy to bind and persist — see `DocumentViewModel.ratios`.
enum SplitLayout: Codable, Equatable {
    case leaf(UUID)
    indirect case split(id: UUID, axis: Axis, SplitLayout, SplitLayout)

    enum Axis: String, Codable {
        case horizontal // children laid out left-to-right (split with a vertical divider)
        case vertical   // children laid out top-to-bottom (split with a horizontal divider)
    }

    /// The viewport ids of every leaf, left-to-right / top-to-bottom.
    var leafIDs: [UUID] {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, _, let first, let second): return first.leafIDs + second.leafIDs
        }
    }

    /// The ids of every split node (used to prune stale ratios).
    var splitIDs: [UUID] {
        switch self {
        case .leaf: return []
        case .split(let id, _, let first, let second): return [id] + first.splitIDs + second.splitIDs
        }
    }

    /// Replaces the `.leaf(id)` with `replacement`, returning the new tree.
    func replacingLeaf(_ id: UUID, with replacement: SplitLayout) -> SplitLayout {
        switch self {
        case .leaf(let leafID):
            return leafID == id ? replacement : self
        case .split(let splitID, let axis, let first, let second):
            return .split(id: splitID, axis: axis,
                          first.replacingLeaf(id, with: replacement),
                          second.replacingLeaf(id, with: replacement))
        }
    }

    /// Finds the split node whose direct child is `.leaf(leafID)`, returning that split's id and
    /// whether the leaf is its first (vs second) child. Used to animate a pane's collapse into its
    /// sibling before it's removed. Returns nil if the leaf isn't found (e.g. it's the only leaf).
    func split(containing leafID: UUID) -> (id: UUID, closingIsFirst: Bool)? {
        switch self {
        case .leaf:
            return nil
        case .split(let splitID, _, let first, let second):
            if case .leaf(leafID) = first { return (splitID, true) }
            if case .leaf(leafID) = second { return (splitID, false) }
            return first.split(containing: leafID) ?? second.split(containing: leafID)
        }
    }

    /// Removes the `.leaf(id)`, collapsing its parent split so the sibling takes its place.
    /// Returns nil if `id` was the only leaf (the caller should keep the tree unchanged).
    func removingLeaf(_ id: UUID) -> SplitLayout? {
        switch self {
        case .leaf(let leafID):
            return leafID == id ? nil : self
        case .split(let splitID, let axis, let first, let second):
            if case .leaf(id) = first { return second }
            if case .leaf(id) = second { return first }
            let newFirst = first.removingLeaf(id) ?? first
            let newSecond = second.removingLeaf(id) ?? second
            return .split(id: splitID, axis: axis, newFirst, newSecond)
        }
    }
}

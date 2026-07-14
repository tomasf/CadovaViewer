import CoreGraphics
import Foundation

/// Works out how dragging one split's divider should change the layout's ratios.
///
/// The panes are stored as a binary tree of ratios, so naively changing a split's ratio rescales its
/// entire first/second subtree — dragging a divider that happens to sit high in the tree moves whole
/// groups of panes at once. Users expect the opposite: a divider only ever moves the panes it
/// physically touches, whatever the tree looks like underneath.
///
/// A horizontal divider touches, on its left, the panes along its first subtree's right edge, and on
/// its right, the panes along its second subtree's left edge. Everything else stays put. To keep the
/// interior pinned we walk the first subtree's rightmost run of *same-axis* splits, holding each of
/// their first children at a fixed size and letting the change flow into the rightmost pane; likewise
/// down the second subtree's leftmost run. A different-axis subtree (e.g. a vertical stack inside a
/// horizontal divider) sits flush against the divider as a block — all of its panes touch it, so it
/// scales as one and needs no interior compensation.
enum DividerDragSolver {
    /// The outcome of a drag: the (clamped) ratio to apply to the dragged split, plus the ratio
    /// updates for the interior splits that keep every non-adjacent pane's size fixed. `updates`
    /// never includes `splitID` itself.
    struct Solution: Equatable {
        var ratio: Double
        var updates: [UUID: Double]
    }

    /// - Parameters:
    ///   - proposedRatio: where the drag wants the divider (first pane's fraction of `available`).
    ///   - available: the dragged split's available extent in points (total minus one divider).
    ///   - ratios: the ratios as they were when the drag began (the interior is pinned to these).
    ///   - minExtent: the smallest a touched pane may become.
    /// - Returns: nil if `splitID` isn't a split in `layout`.
    static func solve(layout: SplitLayout,
                      splitID: UUID,
                      proposedRatio: Double,
                      available: CGFloat,
                      ratios: [UUID: Double],
                      dividerThickness: CGFloat,
                      minExtent: CGFloat) -> Solution? {
        guard let node = layout.node(withSplitID: splitID) else { return nil }
        let available = Double(max(available, 1))
        let d = Double(dividerThickness)
        let minExtent = Double(minExtent)
        let startRatio = ratios[splitID] ?? 0.5

        let firstStart = available * startRatio
        let secondStart = available * (1 - startRatio)

        // The extent that each side's touched (edge) block currently occupies. The remainder on each
        // side is pinned interior, so the drag can't push a touched pane below `minExtent`.
        let firstBlockStart = edgeBlockExtent(node.first, axis: node.axis, extent: firstStart,
                                              ratios: ratios, dividerThickness: d, rightmost: true)
        let secondBlockStart = edgeBlockExtent(node.second, axis: node.axis, extent: secondStart,
                                               ratios: ratios, dividerThickness: d, rightmost: false)
        let pinnedFirst = firstStart - firstBlockStart
        let pinnedSecond = secondStart - secondBlockStart

        let lower = (pinnedFirst + minExtent) / available
        let upper = 1 - (pinnedSecond + minExtent) / available
        let ratio = lower <= upper ? min(max(proposedRatio, lower), upper) : (lower + upper) / 2

        var updates: [UUID: Double] = [:]
        compensate(node.first, axis: node.axis, extentStart: firstStart, extentNew: available * ratio,
                   ratios: ratios, dividerThickness: d, rightmost: true, updates: &updates)
        compensate(node.second, axis: node.axis, extentStart: secondStart, extentNew: available * (1 - ratio),
                   ratios: ratios, dividerThickness: d, rightmost: false, updates: &updates)
        return Solution(ratio: ratio, updates: updates)
    }

    /// Extent of the edge block a divider touches on one side: walk the run of same-axis splits along
    /// the near edge (rightmost of the first subtree, leftmost of the second) and return the size of
    /// the single leaf/opposite-axis block that finally absorbs the change.
    private static func edgeBlockExtent(_ subtree: SplitLayout, axis: SplitLayout.Axis, extent: Double,
                                        ratios: [UUID: Double], dividerThickness d: Double,
                                        rightmost: Bool) -> Double {
        guard case let .split(sid, ax, first, second) = subtree, ax == axis else { return extent }
        let available = extent - d
        let ratio = ratios[sid] ?? 0.5
        if rightmost {
            return edgeBlockExtent(second, axis: axis, extent: available * (1 - ratio),
                                   ratios: ratios, dividerThickness: d, rightmost: true)
        } else {
            return edgeBlockExtent(first, axis: axis, extent: available * ratio,
                                   ratios: ratios, dividerThickness: d, rightmost: false)
        }
    }

    /// Recompute ratios down one side so the interior stays fixed while its edge block absorbs the
    /// side's extent change. `rightmost` walks the first subtree (pin each first child, push into the
    /// second); otherwise walks the second subtree (pin each second child, push into the first).
    private static func compensate(_ subtree: SplitLayout, axis: SplitLayout.Axis,
                                   extentStart: Double, extentNew: Double,
                                   ratios: [UUID: Double], dividerThickness d: Double,
                                   rightmost: Bool, updates: inout [UUID: Double]) {
        guard case let .split(sid, ax, first, second) = subtree, ax == axis else { return }
        let availableStart = extentStart - d
        let availableNew = extentNew - d
        guard availableNew > 0 else { return }
        let ratio = ratios[sid] ?? 0.5

        if rightmost {
            let pinned = availableStart * ratio                       // first child held fixed
            updates[sid] = min(max(pinned / availableNew, 0), 1)
            compensate(second, axis: axis,
                       extentStart: availableStart - pinned, extentNew: availableNew - pinned,
                       ratios: ratios, dividerThickness: d, rightmost: true, updates: &updates)
        } else {
            let pinned = availableStart * (1 - ratio)                 // second child held fixed
            updates[sid] = min(max((availableNew - pinned) / availableNew, 0), 1)
            compensate(first, axis: axis,
                       extentStart: availableStart * ratio, extentNew: availableNew - pinned,
                       ratios: ratios, dividerThickness: d, rightmost: false, updates: &updates)
        }
    }
}

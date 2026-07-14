import Testing
import Foundation
import CoreGraphics
@testable import CadovaViewer

struct DividerDragSolverTests {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID()
    private let rootSplit = UUID(), innerSplit = UUID()

    // (A | B) | C — a left-leaning horizontal chain. The outer divider sits between B and C.
    private func leftLeaning() -> SplitLayout {
        .split(id: rootSplit, axis: .horizontal,
               .split(id: innerSplit, axis: .horizontal, .leaf(a), .leaf(b)),
               .leaf(c))
    }

    // A | (B | C) — a right-leaning horizontal chain. The outer divider sits between A and B.
    private func rightLeaning() -> SplitLayout {
        .split(id: rootSplit, axis: .horizontal,
               .leaf(a),
               .split(id: innerSplit, axis: .horizontal, .leaf(b), .leaf(c)))
    }

    private func solve(_ layout: SplitLayout, split: UUID, to proposed: Double,
                       available: CGFloat = 1000, ratios: [UUID: Double],
                       divider: CGFloat = 0, minExtent: CGFloat = 10) -> DividerDragSolver.Solution {
        DividerDragSolver.solve(layout: layout, splitID: split, proposedRatio: proposed,
                                available: available, ratios: ratios,
                                dividerThickness: divider, minExtent: minExtent)!
    }

    @Test func `dragging a high divider only moves the panes it touches`() {
        // (A|B)|C with A,B,C each 250,250,500. Drag the outer divider (between B and C) to 0.6.
        // Only B and C should change; A stays 250. That means the inner ratio must shrink to keep A
        // fixed while B grows.
        let result = solve(leftLeaning(), split: rootSplit, to: 0.6,
                           ratios: [rootSplit: 0.5, innerSplit: 0.5])
        #expect(result.ratio == 0.6)
        // New group extent is 600; A stays 250 → inner ratio 250/600.
        #expect(abs((result.updates[innerSplit] ?? 0) - 250.0 / 600.0) < 1e-9)
    }

    @Test func `dragging an inner divider touches no other pane`() {
        // The inner divider (between A and B) sits between two leaves, so nothing else needs pinning.
        let result = solve(leftLeaning(), split: innerSplit, to: 0.6, available: 500,
                           ratios: [rootSplit: 0.5, innerSplit: 0.5])
        #expect(result.ratio == 0.6)
        #expect(result.updates.isEmpty)
    }

    @Test func `dragging a right-leaning outer divider pins the far pane`() {
        // A|(B|C) with 500,250,250. Drag the outer divider (between A and B) to 0.4. A and B move,
        // C stays 250 → inner ratio grows so B absorbs the change.
        let result = solve(rightLeaning(), split: rootSplit, to: 0.4,
                           ratios: [rootSplit: 0.5, innerSplit: 0.5])
        #expect(result.ratio == 0.4)
        // New group extent 600; C stays 250 → B = 350 → inner ratio 350/600.
        #expect(abs((result.updates[innerSplit] ?? 0) - 350.0 / 600.0) < 1e-9)
    }

    @Test func `a different-axis subtree scales as one block`() {
        // (A/B)|C where (A/B) is a *vertical* stack: both A and B touch the vertical divider, so the
        // whole block resizes together with no interior compensation.
        let layout = SplitLayout.split(id: rootSplit, axis: .horizontal,
                                       .split(id: innerSplit, axis: .vertical, .leaf(a), .leaf(b)),
                                       .leaf(c))
        let result = solve(layout, split: rootSplit, to: 0.6,
                           ratios: [rootSplit: 0.5, innerSplit: 0.5])
        #expect(result.ratio == 0.6)
        #expect(result.updates.isEmpty)
    }

    @Test func `the interior stays fixed with a real divider thickness`() {
        // Same (A|B)|C, but with a 5pt divider. A must still stay exactly where it was.
        let result = solve(leftLeaning(), split: rootSplit, to: 0.6,
                           ratios: [rootSplit: 0.5, innerSplit: 0.5], divider: 5)
        // Group extent 500 → inner available 495 → A = 247.5. New group 600 → inner available 595.
        // To keep A at 247.5 the inner ratio is 247.5/595.
        #expect(abs((result.updates[innerSplit] ?? 0) - 247.5 / 595.0) < 1e-9)
    }

    @Test func `a touched pane can't be dragged below the minimum`() {
        // (A|B)|C, drag the outer divider hard right. C is the pane on the divider's right; it must
        // not shrink past minExtent (100 here), so the ratio clamps to leave C exactly 100 wide.
        let result = solve(leftLeaning(), split: rootSplit, to: 0.99,
                           ratios: [rootSplit: 0.5, innerSplit: 0.5], minExtent: 100)
        // C = 1000·(1 - ratio) ≥ 100 → ratio ≤ 0.9.
        #expect(abs(result.ratio - 0.9) < 1e-9)
    }

    @Test func `pinning keeps a whole far group fixed`() {
        // A|(B|(C|D)) 500,250,125,125. Drag the outer divider (between A and B) to 0.4. Only A and B
        // move; the C|D group stays put as a unit (one inner-ratio update, none for the deepest split).
        let deepSplit = UUID()
        let layout = SplitLayout.split(id: rootSplit, axis: .horizontal,
                                       .leaf(a),
                                       .split(id: innerSplit, axis: .horizontal,
                                              .leaf(b),
                                              .split(id: deepSplit, axis: .horizontal, .leaf(c), .leaf(d))))
        let result = solve(layout, split: rootSplit, to: 0.4,
                           ratios: [rootSplit: 0.5, innerSplit: 0.5, deepSplit: 0.5])
        // Group was 500 (B=250, C|D=250). New group 600, C|D stays 250 → B=350 → inner ratio 350/600.
        #expect(abs((result.updates[innerSplit] ?? 0) - 350.0 / 600.0) < 1e-9)
        #expect(result.updates[deepSplit] == nil)
    }
}

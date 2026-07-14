import SwiftUI

/// Renders the document's `SplitLayout` tree: each `.leaf` is a `ViewportContentView`, each
/// `.split` is a `ResizableSplit` whose divider drives the ratio stored in the view model.
struct ViewportSplitView: View {
    @ObservedObject var viewModel: DocumentViewModel

    var body: some View {
        layoutView(viewModel.layout)
    }

    @ViewBuilder
    private func layoutView(_ layout: SplitLayout) -> some View {
        switch layout {
        case .leaf(let id):
            if let viewport = viewModel.viewports[id] {
                ViewportContentView(viewModel: viewModel, viewportController: viewport, viewportID: id)
            }
        case .split(let splitID, let axis, let first, let second):
            ResizableSplit(
                axis: axis,
                ratio: viewModel.ratio(for: splitID),
                animating: viewModel.animatingSplitID == splitID,
                onResizeActiveChanged: { [weak viewModel] active in
                    viewModel?.viewports.values.forEach { viewport in
                        if active {
                            viewport.sceneView.beginPaneResize(axis: axis)
                        } else {
                            viewport.sceneView.endPaneResize()
                        }
                    }
                },
                first: { AnyView(layoutView(first)) },
                second: { AnyView(layoutView(second)) }
            )
        }
    }
}

/// Two panes separated by a draggable divider. `ratio` is the first pane's fraction of the
/// available space (clamped so each pane stays at least the minimum size).
struct ResizableSplit<First: View, Second: View>: View {
    let axis: SplitLayout.Axis
    @Binding var ratio: Double
    /// While true (this split is animating a pane open/closed) the per-pane minimum-size clamp is
    /// skipped so the ratio can reach 0 or 1 and a pane can fully grow-from / collapse-to zero.
    var animating: Bool = false
    var onResizeActiveChanged: (Bool) -> Void = { _ in }
    @ViewBuilder var first: () -> First
    @ViewBuilder var second: () -> Second

    @State private var spaceID = UUID()
    @State private var dragRatio: Double?
    @State private var resizeActive = false

    var body: some View {
        GeometryReader { geo in
            let horizontal = axis == .horizontal
            let total = horizontal ? geo.size.width : geo.size.height
            let available = max(total - ViewportLayoutMetrics.dividerThickness, 1)
            let minExtent = horizontal ? ViewportLayoutMetrics.minPaneWidth : ViewportLayoutMetrics.minPaneHeight
            let proposedRatio = dragRatio ?? ratio
            let effectiveRatio = animating ? min(max(proposedRatio, 0), 1) : clampedRatio(proposedRatio, available: available, minExtent: minExtent)
            let firstExtent = available * effectiveRatio

            stack(horizontal: horizontal) {
                first()
                    .frame(width: horizontal ? firstExtent : nil,
                           height: horizontal ? nil : firstExtent)
                    .clipped()
                divider(horizontal: horizontal, available: available, minExtent: minExtent)
                second()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
            .coordinateSpace(.named(spaceID))
        }
    }

    @ViewBuilder
    private func stack(horizontal: Bool, @ViewBuilder content: () -> some View) -> some View {
        if horizontal {
            HStack(spacing: 0, content: content)
        } else {
            VStack(spacing: 0, content: content)
        }
    }

    private func clampedRatio(_ ratio: Double, available: CGFloat, minExtent: CGFloat) -> Double {
        let minRatio = Double(minExtent / available)
        guard minRatio < 0.5 else { return 0.5 } // not enough room for two min panes
        return min(max(ratio, minRatio), 1 - minRatio)
    }

    private func divider(horizontal: Bool, available: CGFloat, minExtent: CGFloat) -> some View {
        Rectangle()
            .fill(ViewportLayoutMetrics.backgroundColor)
            .frame(width: horizontal ? ViewportLayoutMetrics.dividerThickness : nil,
                   height: horizontal ? nil : ViewportLayoutMetrics.dividerThickness)
            .overlay {
                Rectangle().fill(Color.white.opacity(0.12))
                    .frame(width: horizontal ? 1 : nil, height: horizontal ? nil : 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(coordinateSpace: .named(spaceID))
                    .onChanged { value in
                        if !resizeActive {
                            resizeActive = true
                            onResizeActiveChanged(true)
                        }
                        let location = horizontal ? value.location.x : value.location.y
                        dragRatio = clampedRatio(Double(location) / Double(available), available: available, minExtent: minExtent)
                    }
                    .onEnded { value in
                        let location = horizontal ? value.location.x : value.location.y
                        let finalRatio = clampedRatio(Double(location) / Double(available), available: available, minExtent: minExtent)
                        var transaction = Transaction()
                        transaction.animation = nil
                        withTransaction(transaction) {
                            ratio = finalRatio
                        }
                        DispatchQueue.main.async {
                            var transaction = Transaction()
                            transaction.animation = nil
                            withTransaction(transaction) {
                                dragRatio = nil
                                resizeActive = false
                            }
                            onResizeActiveChanged(false)
                        }
                    }
            )
            .onHover { inside in
                if inside {
                    (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
    }
}

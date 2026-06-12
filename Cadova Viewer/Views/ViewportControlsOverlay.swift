import SwiftUI

/// Top-right per-viewport controls: split this viewport side-by-side or top-and-bottom, and
/// (when there's more than one viewport) close it. Split buttons disable when the viewport is too
/// small to yield two panes that each meet the minimum size.
struct ViewportControlsOverlay: View {
    @ObservedObject var viewModel: DocumentViewModel
    let viewportID: UUID
    let size: CGSize

    private func canSplit(_ axis: SplitLayout.Axis) -> Bool {
        let availableSize = axis == .horizontal ? size.width : size.height
        let minimumPaneSize = axis == .horizontal ? ViewportLayoutMetrics.minPaneWidth : ViewportLayoutMetrics.minPaneHeight
        return availableSize >= minimumPaneSize * 2 + ViewportLayoutMetrics.dividerThickness
    }

    var body: some View {
        HStack(spacing: 6) {
            Menu {
                Button {
                    viewModel.split(viewportID, axis: .horizontal)
                } label: {
                    Label("Split Horizontally", systemImage: "rectangle.split.2x1")
                }
                .disabled(!canSplit(.horizontal))

                Button {
                    viewModel.split(viewportID, axis: .vertical)
                } label: {
                    Label("Split Vertically", systemImage: "rectangle.split.1x2")
                }
                .disabled(!canSplit(.vertical))
            } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
            }
            .help("Split Viewport")
            .disabled(!canSplit(.horizontal) && !canSplit(.vertical))

            if viewModel.hasMultipleViewports {
                Button {
                    viewModel.close(viewportID)
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Close Viewport")
            }
        }
        .buttonStyle(BlurButtonStyle())
        .controlSize(.large)
        .padding(6)
    }
}

/// Shared minimum-size / divider metrics for viewport splitting.
enum ViewportLayoutMetrics {
    static let minPaneWidth: CGFloat = 280
    static let minPaneHeight: CGFloat = 180
    static let dividerThickness: CGFloat = 5
}

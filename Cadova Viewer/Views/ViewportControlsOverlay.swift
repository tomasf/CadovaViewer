import SwiftUI

/// Top-right per-viewport controls: split this viewport side-by-side or top-and-bottom, and
/// (when there's more than one viewport) close it. Split buttons disable when the viewport is too
/// small to yield two panes that each meet the minimum size.
struct ViewportControlsOverlay: View {
    @ObservedObject var viewModel: DocumentViewModel
    let viewportID: UUID
    let size: CGSize

    var body: some View {
        HStack(spacing: 4) {
            Button {
                viewModel.split(viewportID, axis: .horizontal)
            } label: {
                Image(systemName: "rectangle.split.2x1")
            }
            .help("Split Side by Side")
            .disabled(size.width < ViewportLayoutMetrics.minPaneWidth * 2 + ViewportLayoutMetrics.dividerThickness)

            Button {
                viewModel.split(viewportID, axis: .vertical)
            } label: {
                Image(systemName: "rectangle.split.1x2")
            }
            .help("Split Top and Bottom")
            .disabled(size.height < ViewportLayoutMetrics.minPaneHeight * 2 + ViewportLayoutMetrics.dividerThickness)

            if viewModel.hasMultipleViewports {
                Button(role: .destructive) {
                    viewModel.close(viewportID)
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Close Viewport")
            }
        }
        .buttonStyle(BlurButtonStyle())
        .controlSize(.large)
        .padding(8)
    }
}

/// Shared minimum-size / divider metrics for viewport splitting.
enum ViewportLayoutMetrics {
    static let minPaneWidth: CGFloat = 280
    static let minPaneHeight: CGFloat = 180
    static let dividerThickness: CGFloat = 8
}

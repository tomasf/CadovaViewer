import SwiftUI
import ViewerCore

/// One viewport pane: its scene view plus the per-viewport overlays (measurement list, parts
/// list, axis indicator), the top-right split/close controls, and a focus border when the
/// document has more than one viewport.
struct ViewportContentView: View {
    @ObservedObject var viewModel: DocumentViewModel
    @ObservedObject var viewportController: ViewportController
    let viewportID: UUID

    /// The pane's size, mirrored into SwiftUI state so the split controls' enabled state stays in
    /// sync (the controller's `sceneViewSize` is a plain property and doesn't trigger a re-render).
    @State private var paneSize: CGSize = .zero

    private var isFocused: Bool { viewModel.focusedViewportID == viewportID }

    var body: some View {
        ViewerSceneView(viewportController: viewportController)
            .onGeometryChange(for: CGSize.self, of: { $0.size }) {
                viewportController.sceneViewSize = $0
                viewportController.sceneView.overlaySKScene?.size = $0
                paneSize = $0
            }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let point): viewportController.hoverPoint = point
                case .ended: viewportController.hoverPoint = nil
                }
            }
            // A click (not a drag) focuses this viewport without stealing the camera drag.
            .simultaneousGesture(TapGesture().onEnded { viewModel.focus(viewportID) })
            .overlay(alignment: .topLeading) {
                MeasurementListOverlay(controller: viewportController.measurementController)
            }
            .overlay(alignment: .bottomLeading) {
                PartListOverlay(viewportController: viewportController)
            }
            .overlay(alignment: .bottomTrailing) {
                if viewportController.viewOptions.showCoordinateSystemIndicator {
                    CoordinateSystemIndicator(stream: viewportController.coordinateIndicatorValues)
                        .padding()
                }
            }
            .overlay(alignment: .topTrailing) {
                ViewportControlsOverlay(viewModel: viewModel, viewportID: viewportID, size: paneSize)
            }
            .overlay {
                if viewModel.hasMultipleViewports {
                    Rectangle()
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .opacity(isFocused ? 1 : 0)
                        .allowsHitTesting(false)
                }
            }
    }
}

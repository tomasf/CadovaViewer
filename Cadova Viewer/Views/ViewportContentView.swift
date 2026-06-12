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

    /// The focus ring flashes on when this pane gains focus, then fades out, so it signals the
    /// change without staying on permanently.
    @State private var focusRingOpacity: Double = 0

    private var isFocused: Bool { viewModel.focusedViewportID == viewportID }

    var body: some View {
        ViewerSceneView(viewportController: viewportController)
            // A dark backing so a freshly-created pane (before its scene view first renders) shows
            // the viewport's background colour rather than flashing white.
            .background(Color(white: 0.05))
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
                        .opacity(focusRingOpacity)
                        .allowsHitTesting(false)
                }
            }
            .onChange(of: isFocused) { _, focused in flashFocusRing(focused) }
            // Flash the initially-focused pane too (e.g. the new pane right after a split).
            .onAppear { if isFocused { flashFocusRing(true) } }
    }

    private func flashFocusRing(_ focused: Bool) {
        if focused {
            focusRingOpacity = 1
            withAnimation(.easeOut(duration: 0.6).delay(0.4)) { focusRingOpacity = 0 }
        } else {
            withAnimation(.easeOut(duration: 0.2)) { focusRingOpacity = 0 }
        }
    }
}

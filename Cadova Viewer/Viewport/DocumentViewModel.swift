import SwiftUI
import Combine
import ViewerCore

/// Per-document coordinator for the (possibly split) set of viewports. Owns the shared
/// `SceneController`, the live `ViewportController`s keyed by leaf id, the split layout tree and
/// its divider ratios, and which viewport is focused. `DocumentView` observes this; the toolbar
/// and menus act on `focusedViewport`.
final class DocumentViewModel: ObservableObject {
    let sceneController: SceneController
    weak var document: Document?

    @Published private(set) var layout: SplitLayout
    @Published private(set) var viewports: [UUID: ViewportController] = [:]
    @Published var ratios: [UUID: Double] = [:]
    @Published var focusedViewportID: UUID {
        didSet { focusDidChange() }
    }

    /// Re-publishes this model whenever the focused viewport (or its measurement controller)
    /// changes, so the focus-following toolbar in `DocumentView` refreshes.
    private var focusObservers: Set<AnyCancellable> = []

    /// Long-lived subscriptions (document-global options → restorable state).
    private var cancellables: Set<AnyCancellable> = []

    var focusedViewport: ViewportController {
        viewports[focusedViewportID] ?? viewports[layout.leafIDs[0]]!
    }

    var hasMultipleViewports: Bool { viewports.count > 1 }

    init(document: Document) {
        self.document = document
        sceneController = SceneController(document: document)

        let id = UUID()
        layout = .leaf(id)
        focusedViewportID = id
        viewports[id] = makeViewport(id: id, document: document)
        focusDidChange()

        // The document-global geometry options are part of the saved state.
        sceneController.$documentOptions.dropFirst().sink { [weak self] _ in
            self?.document?.invalidateRestorableState()
        }.store(in: &cancellables)
    }

    /// Creates a viewport wired back to this view model (so its scene view can request focus and
    /// its menu can split/close/cycle focus).
    private func makeViewport(id: UUID, document: Document) -> ViewportController {
        let viewport = ViewportController(viewportID: id, document: document, sceneController: sceneController)
        viewport.documentViewModel = self
        return viewport
    }

    /// Reacts to a focus change: refresh the toolbar forwarding, update each viewport's focus flag,
    /// and hand the active NavLib (SpaceMouse) session to the newly focused viewport.
    private func focusDidChange() {
        observeFocusedViewport()
        for (id, viewport) in viewports {
            viewport.isFocusedViewport = (id == focusedViewportID)
            viewport.updateNavLibFocus()
        }
        document?.invalidateRestorableState()
    }

    private func observeFocusedViewport() {
        focusObservers.removeAll()
        guard let viewport = viewports[focusedViewportID] else { return }
        for publisher in [viewport.objectWillChange, viewport.measurementController.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &focusObservers)
        }
    }

    func ratio(for splitID: UUID) -> Binding<Double> {
        Binding(get: { [weak self] in self?.ratios[splitID] ?? 0.5 },
                set: { [weak self] in
                    self?.ratios[splitID] = $0
                    self?.document?.invalidateRestorableState()
                })
    }

    // MARK: - Split / close

    func split(_ id: UUID, axis: SplitLayout.Axis) {
        guard let document, let source = viewports[id] else { return }

        let newID = UUID()
        let viewport = makeViewport(id: newID, document: document)
        // A new viewport starts with a clean clone of the model; mirror the source viewport's
        // options (camera, grid, hidden parts) so the split starts out identical to it.
        viewport.setViewOptions(source.viewOptions)
        // The model is already loaded (the source viewport exists), so build this viewport's clone
        // and run the model-dependent setup the modelWasLoaded sink would otherwise do.
        if !sceneController.parts.isEmpty {
            viewport.applyLoadedModel()
        }

        let splitID = UUID()
        viewports[newID] = viewport
        ratios[splitID] = 0.5
        layout = layout.replacingLeaf(id, with: .split(id: splitID, axis: axis, .leaf(id), .leaf(newID)))
        focusedViewportID = newID
    }

    func close(_ id: UUID) {
        guard viewports.count > 1, let newLayout = layout.removingLeaf(id) else { return }
        let viewport = viewports.removeValue(forKey: id)
        layout = newLayout
        let validSplits = Set(layout.splitIDs)
        ratios = ratios.filter { validSplits.contains($0.key) }
        viewport?.tearDown()
        if viewports[focusedViewportID] == nil {
            focusedViewportID = layout.leafIDs[0]
        }
    }

    // MARK: - Focus

    func focus(_ id: UUID) {
        guard viewports[id] != nil, id != focusedViewportID else { return }
        focusedViewportID = id
    }

    /// Moves focus to the next/previous leaf in layout order, wrapping around.
    func focusAdjacentViewport(forward: Bool) {
        let ids = layout.leafIDs
        guard let index = ids.firstIndex(of: focusedViewportID), ids.count > 1 else { return }
        let next = (index + (forward ? 1 : ids.count - 1)) % ids.count
        focus(ids[next])
    }

    // MARK: - State restoration

    /// Captures the full layout (tree, divider ratios, focus, each viewport's options, and the
    /// document-global geometry options) for `NSDocument` restorable state.
    func snapshot() -> DocumentLayoutState {
        DocumentLayoutState(
            layout: layout,
            ratios: ratios,
            focusedViewportID: focusedViewportID,
            viewOptions: viewports.mapValues(\.viewOptions),
            documentOptions: sceneController.documentOptions
        )
    }

    /// Rebuilds the viewports and layout from a saved snapshot, replacing the initial single
    /// viewport. Applies each viewport's options now; if the model hasn't loaded yet, each
    /// viewport's `modelWasLoaded` sink builds its clone later (the restored camera is preserved).
    func restore(_ state: DocumentLayoutState) {
        guard let document, !state.layout.leafIDs.isEmpty else { return }

        for viewport in viewports.values { viewport.tearDown() }

        sceneController.documentOptions = state.documentOptions

        var rebuilt: [UUID: ViewportController] = [:]
        for id in state.layout.leafIDs {
            let viewport = makeViewport(id: id, document: document)
            if let options = state.viewOptions[id] {
                viewport.setViewOptions(options)
            }
            if !sceneController.parts.isEmpty {
                viewport.applyLoadedModel()
            }
            rebuilt[id] = viewport
        }

        viewports = rebuilt
        ratios = state.ratios
        layout = state.layout
        focusedViewportID = state.layout.leafIDs.contains(state.focusedViewportID)
            ? state.focusedViewportID : state.layout.leafIDs[0]
        focusDidChange()
    }
}

/// The persisted shape of a document's viewport layout (see `DocumentViewModel.snapshot`).
struct DocumentLayoutState: Codable {
    var layout: SplitLayout
    var ratios: [UUID: Double]
    var focusedViewportID: UUID
    var viewOptions: [UUID: ViewOptions]
    var documentOptions: DocumentViewOptions
}

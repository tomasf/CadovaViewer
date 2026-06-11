import SwiftUI
import Combine
import ViewerCore

/// Per-document coordinator for the (possibly split) set of viewports. Owns the shared
/// `SceneController`, the live `ViewportController`s keyed by leaf id, the split layout tree and
/// its divider ratios, and which viewport is focused. Also allocates/frees the per-viewport
/// category bit. `DocumentView` observes this; the toolbar and menus act on `focusedViewport`.
final class DocumentViewModel: ObservableObject {
    let sceneController: SceneController
    weak var document: Document?

    @Published private(set) var layout: SplitLayout
    @Published private(set) var viewports: [UUID: ViewportController] = [:]
    @Published var ratios: [UUID: Double] = [:]
    @Published var focusedViewportID: UUID {
        didSet { observeFocusedViewport() }
    }

    /// Bit 0 is the universal mask (see `GlobalCategoryMasks`); viewports take bits 1+.
    private var usedCategoryMasks = GlobalCategoryMasks.universal.rawValue

    /// Re-publishes this model whenever the focused viewport (or its measurement controller)
    /// changes, so the focus-following toolbar in `DocumentView` refreshes.
    private var focusObservers: Set<AnyCancellable> = []

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
        // First viewport takes the first free bit (1); subsequent ones are added by `split`.
        let categoryID = (~usedCategoryMasks).trailingZeroBitCount
        usedCategoryMasks |= (1 << categoryID)
        viewports[id] = ViewportController(
            document: document, sceneController: sceneController,
            categoryID: categoryID, privateContainer: sceneController.viewportPrivateNode(for: categoryID)
        )
        observeFocusedViewport()
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
                set: { [weak self] in self?.ratios[splitID] = $0 })
    }

    // MARK: - Split / close

    func split(_ id: UUID, axis: SplitLayout.Axis) {
        guard let document, let source = viewports[id] else { return }

        let categoryID = (~usedCategoryMasks).trailingZeroBitCount
        usedCategoryMasks |= (1 << categoryID)
        let viewport = ViewportController(
            document: document, sceneController: sceneController,
            categoryID: categoryID, privateContainer: sceneController.viewportPrivateNode(for: categoryID)
        )
        // The reused bit may carry stale per-viewport hidden state; make every part visible in
        // the new viewport, then mirror the source viewport's options so it starts identical.
        for part in sceneController.parts {
            part.nodes.container.setVisible(true, forViewportID: categoryID)
        }
        viewport.setViewOptions(source.viewOptions)
        // The model is already loaded (the source viewport exists), so run the per-viewport
        // model setup the modelWasLoaded sink would otherwise do (grid bounds, snap vertices).
        if !sceneController.parts.isEmpty {
            viewport.applyLoadedModel()
        }

        let newID = UUID()
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
        if let viewport {
            usedCategoryMasks &= ~(1 << viewport.categoryID)
            viewport.tearDown()
            sceneController.removeViewportPrivateNode(for: viewport.categoryID)
        }
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
}

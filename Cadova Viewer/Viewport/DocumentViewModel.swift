import SwiftUI
import Combine
import AppKit
import SceneKit
import NavLib
import ViewerCore

/// Per-document coordinator for the (possibly split) set of viewports. Owns the shared
/// `SceneController`, the live `ViewportController`s keyed by leaf id, the split layout tree and
/// its divider ratios, and which viewport is focused. `DocumentView` observes this; the toolbar
/// and menus act on `focusedViewport`.
final class DocumentViewModel: ObservableObject {
    let sceneController: SceneController
    /// Document-global measurements, shared by every viewport and drawn in each.
    let measurements = MeasurementController()
    /// One SpaceMouse (NavLib) session for the whole document. Its state provider is re-pointed to
    /// the focused viewport, so exactly one session always drives whichever viewport has focus —
    /// avoiding the multiple-active-session routing problem of a session per viewport.
    let navLibSession = NavLibSession<SCNVector3>()
    private var navLibActive = false
    weak var document: Document?

    @Published private(set) var layout: SplitLayout
    @Published private(set) var viewports: [UUID: ViewportController] = [:]
    @Published var ratios: [UUID: Double] = [:]
    @Published var focusedViewportID: UUID {
        didSet { focusDidChange() }
    }

    /// Whether the window-global document sidebar is shown. Window-level UI state, persisted with the
    /// document's restorable state so a reopened document keeps its last open/closed choice.
    @Published var sidebarVisibility: NavigationSplitViewVisibility = .detailOnly {
        didSet { document?.invalidateRestorableState() }
    }

    /// Toggles the document sidebar open/closed, animated to match the standard sidebar show/hide. Shared
    /// by the toolbar button and the View menu item.
    func toggleSidebar() {
        withAnimation {
            sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
        }
    }

    /// Re-publishes this model whenever the focused viewport changes, so the focus-following
    /// toolbar in `DocumentView` refreshes.
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
        measurements.undoManager = document.interactionUndoManager
        viewports[id] = makeViewport(id: id, document: document)
        focusDidChange()

        // The document-global geometry options are part of the saved state.
        sceneController.$documentOptions.dropFirst().sink { [weak self] _ in
            self?.document?.invalidateRestorableState()
        }.store(in: &cancellables)

        // The toolbar's measurement mode picker follows the shared mode. (The list overlay observes
        // the controller directly, so only the mode needs to be forwarded here.)
        measurements.$interactionMode.dropFirst().sink { [weak self] _ in
            self?.objectWillChange.send()
        }.store(in: &cancellables)

        measurements.didChange.sink { [weak self] _ in
            self?.showSidebarIfMeasurementsAreVisible()
        }.store(in: &cancellables)

        // Start the document's single SpaceMouse session off the critical path (NlCreate blocks).
        DispatchQueue.main.async { [weak self] in self?.startNavLib() }
    }

    /// Creates a viewport wired back to this view model (so its scene view can request focus and
    /// its menu can split/close/cycle focus).
    private func makeViewport(id: UUID, document: Document) -> ViewportController {
        let viewport = ViewportController(viewportID: id, document: document, sceneController: sceneController, measurements: measurements)
        viewport.documentViewModel = self
        return viewport
    }

    /// Reacts to a focus change: refresh the toolbar forwarding, point the SpaceMouse session at the
    /// newly focused viewport, and update each viewport's focus flag.
    private func focusDidChange() {
        observeFocusedViewport()
        navLibSession.stateProvider = focusedViewport
        for (id, viewport) in viewports {
            viewport.isFocusedViewport = (id == focusedViewportID)
        }
        document?.invalidateRestorableState()
    }

    private func observeFocusedViewport() {
        focusObservers.removeAll()
        guard let viewport = viewports[focusedViewportID] else { return }
        viewport.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &focusObservers)
    }

    private func showSidebarIfMeasurementsAreVisible() {
        guard sidebarVisibility == .detailOnly,
              measurements.hoverPreview != nil || !measurements.measurements.isEmpty else { return }
        withAnimation {
            sidebarVisibility = .all
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
        // Mirror the source viewport's options (camera, grid, hidden parts) so the split starts out
        // identical to it. This is cheap; the model clone is built afterwards.
        viewport.setViewOptions(source.viewOptionsForStateRestoration)

        let splitID = UUID()
        viewports[newID] = viewport
        ratios[splitID] = 0.5
        layout = layout.replacingLeaf(id, with: .split(id: splitID, axis: axis, .leaf(id), .leaf(newID)))
        focusedViewportID = newID

        // Build this viewport's clone of the model *after* the split has rendered, so the new pane
        // appears immediately rather than waiting on the (potentially heavy) clone + snap-vertex
        // work. The `modelWasLoaded` sink covers the case where the model isn't loaded yet.
        if !sceneController.parts.isEmpty {
            DispatchQueue.main.async { viewport.applyLoadedModel() }
        }
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

    // MARK: - SpaceMouse (NavLib)

    /// Starts the document's single NavLib session (driving the focused viewport via its state
    /// provider) and tracks when this document should receive SpaceMouse input.
    private func startNavLib() {
        do {
            try navLibSession.start(stateProvider: focusedViewport, applicationName: "Model Viewer")
        } catch {
            print("NavLib initialization failed: \(error)")
        }
        updateNavLibActive()

        NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateNavLibActive() }
            .store(in: &cancellables)

        NSWorkspace.shared.publisher(for: \.frontmostApplication).sink { [weak self] runningApp in
            guard let self, let runningApp, navLibActive else { return }

            if runningApp.bundleIdentifier == Bundle.main.bundleIdentifier {
                navLibSession.applicationHasFocus = true
                return
            }

            let active = switch Preferences().navLibActivationBehavior {
            case .always: true
            case .foregroundOnly: runningApp.bundleIdentifier == Bundle.main.bundleIdentifier
            case .specificApplicationsInForeground: Preferences().navLibWhitelistedApps.map(\.bundleIdentifier).contains(runningApp.bundleIdentifier)
            }
            navLibSession.applicationHasFocus = active
        }.store(in: &cancellables)
    }

    /// Makes this document's session active while its window is the main one. (Across documents the
    /// most recently activated session wins; within a document there's only this one session.)
    private func updateNavLibActive() {
        if let main = NSApp.mainWindow, NSDocumentController.shared.document(for: main) === document {
            navLibSession.setAsActiveSession()
            navLibSession.applicationHasFocus = true
            navLibActive = true
        } else {
            navLibActive = false
        }
    }

    // MARK: - State restoration

    /// Captures the full layout (tree, divider ratios, focus, each viewport's options, and the
    /// document-global geometry options) for `NSDocument` restorable state.
    func snapshot() -> DocumentLayoutState {
        DocumentLayoutState(
            layout: layout,
            ratios: ratios,
            focusedViewportID: focusedViewportID,
            viewOptions: viewports.mapValues(\.viewOptionsForStateRestoration),
            documentOptions: sceneController.documentOptions,
            sidebarVisible: sidebarVisibility != .detailOnly,
            crossSections: viewports.mapValues(\.crossSections)
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
            let restoredCrossSections = state.crossSections?[id] ?? []
            viewport.crossSections = restoredCrossSections
            // Keep new cuts' colours from colliding with restored ones.
            viewport.nextCrossSectionColorIndex = (restoredCrossSections.map(\.colorIndex).max() ?? -1) + 1
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
        sidebarVisibility = (state.sidebarVisible ?? false) ? .all : .detailOnly
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
    /// Optional so documents saved before the sidebar existed still decode (treated as closed).
    var sidebarVisible: Bool?
    /// Per-viewport cross-section planes. Optional so documents saved before cross-sections decode.
    var crossSections: [UUID: [CrossSection]]?
}

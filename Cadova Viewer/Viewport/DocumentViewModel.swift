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
    /// The split currently animating a pane open (on split) or closed (on close). While set, that
    /// split ignores its min-size clamp so the pane can fully grow-from / collapse-to zero. Transient
    /// UI state — not persisted with the document.
    @Published private(set) var animatingSplitID: UUID?
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
    /// A viewport can publish while SwiftUI is applying a control update (for example, when a
    /// toolbar picker writes through its binding). Forwarding that notification synchronously
    /// re-enters the document view's update pass and triggers SwiftUI's "Publishing changes from
    /// within view updates" diagnostic. Coalesce the forwarding onto the next run-loop turn.
    private var focusedViewportRefreshScheduled = false

    /// Long-lived subscriptions (document-global options → restorable state).
    private var cancellables: Set<AnyCancellable> = []

    /// The focused viewport, with fallbacks. During state restoration `viewports`, `layout`, and
    /// `focusedViewportID` are set in separate `@Published` writes, so a SwiftUI re-evaluation can read
    /// this while they briefly disagree. Resolve defensively rather than force-unwrapping a stale id.
    var focusedViewport: ViewportController {
        if let viewport = viewports[focusedViewportID] { return viewport }
        if let leaf = layout.leafIDs.first(where: { viewports[$0] != nil }) { return viewports[leaf]! }
        return viewports.values.first!
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

        // The toolbar's measurement mode picker follows the shared mode. (The list overlay observes
        // the controller directly, so only the mode needs to be forwarded here.)
        measurements.$interactionMode.dropFirst().sink { [weak self] _ in
            self?.scheduleFocusedViewportRefresh()
        }.store(in: &cancellables)

        measurements.didChange.sink { [weak self] change in
            self?.showSidebarIfMeasurementsAreVisible()
            // Only structural changes (add/remove/complete) alter the persisted set; live cursor
            // moves and highlight changes don't, so don't re-encode the restorable state for those.
            if case .structural = change { self?.document?.invalidateRestorableState() }
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
        viewport.objectWillChange.sink { [weak self] _ in
            self?.scheduleFocusedViewportRefresh()
        }.store(in: &focusObservers)
    }

    /// Publishes one document-level refresh after the active SwiftUI/AppKit update has completed.
    /// This is intentionally separate from the viewport's own notification: pane-local views still
    /// update immediately, while the document-level toolbar/sidebar refresh is safely deferred.
    private func scheduleFocusedViewportRefresh() {
        guard !focusedViewportRefreshScheduled else { return }
        focusedViewportRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            focusedViewportRefreshScheduled = false
            objectWillChange.send()
        }
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

    /// Spring used to grow a new pane in (split) and collapse a pane into its sibling (close).
    /// Matches the app's cross-section overlay spring for a consistent feel.
    private static let paneAnimation: Animation = .spring(response: 0.32, dampingFraction: 0.88)

    func split(_ id: UUID, axis: SplitLayout.Axis) {
        guard animatingSplitID == nil else { return }
        guard let document, let source = viewports[id] else { return }

        let newID = UUID()
        let viewport = makeViewport(id: newID, document: document)
        // Mirror the source viewport's options (camera, grid, hidden parts) so the split starts out
        // identical to it. This is cheap; the model clone is built afterwards.
        viewport.setViewOptions(source.viewOptionsForStateRestoration)
        // Cross-sections live outside ViewOptions, so copy them too — the split is a duplicate of the
        // view. They're applied when the new viewport's model clone loads (applyLoadedModel). Carry the
        // colour counter so sections added later in the new pane keep distinct colours.
        viewport.crossSections = source.crossSections
        viewport.nextCrossSectionColorIndex = source.nextCrossSectionColorIndex

        let splitID = UUID()
        viewports[newID] = viewport
        // Start with the new pane (the split's second child) collapsed so it grows in from the
        // divider; `animatingSplitID` lets the split reach ratio 1.0 past its normal min-size clamp.
        animatingSplitID = splitID
        ratios[splitID] = 1.0
        layout = layout.replacingLeaf(id, with: .split(id: splitID, axis: axis, .leaf(id), .leaf(newID)))
        focusedViewportID = newID

        // On the next runloop tick — after the split has rendered at ratio 1.0 — animate it open to
        // 50/50. Animating in the same update would just render the final ratio with no motion.
        DispatchQueue.main.async {
            // Build this viewport's clone of the model *before* the animation's clock starts. It's
            // deferred off the first tick so the empty pane appears immediately, but doing it after
            // `withAnimation` had already started would block the animation's opening frames and make
            // it stutter. The `modelWasLoaded` sink covers the case where the model isn't loaded yet.
            if !self.sceneController.parts.isEmpty {
                viewport.applyLoadedModel()
            }
            withAnimation(Self.paneAnimation) {
                self.ratios[splitID] = 0.5
            } completion: {
                self.animatingSplitID = nil
            }
        }
    }

    func close(_ id: UUID) {
        guard animatingSplitID == nil else { return }
        guard viewports.count > 1, let parent = layout.split(containing: id) else { return }

        // Collapse the closing pane into its sibling first, then remove it once the animation ends.
        // `animatingSplitID` lets the split's ratio reach the extreme past its normal min-size clamp.
        animatingSplitID = parent.id
        withAnimation(Self.paneAnimation) {
            self.ratios[parent.id] = parent.closingIsFirst ? 0.0 : 1.0
        } completion: {
            self.animatingSplitID = nil
            guard let newLayout = self.layout.removingLeaf(id) else { return }
            let viewport = self.viewports.removeValue(forKey: id)
            self.layout = newLayout
            let validSplits = Set(self.layout.splitIDs)
            self.ratios = self.ratios.filter { validSplits.contains($0.key) }
            viewport?.tearDown()
            if self.viewports[self.focusedViewportID] == nil {
                self.focusedViewportID = self.layout.leafIDs[0]
            }
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
            case .allExceptSpecificApplications: !Preferences().navLibExcludedApps.map(\.bundleIdentifier).contains(runningApp.bundleIdentifier)
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

    /// Captures the full layout (tree, divider ratios, focus, and each viewport's options) for
    /// `NSDocument` restorable state.
    func snapshot() -> DocumentLayoutState {
        DocumentLayoutState(
            layout: layout,
            ratios: ratios,
            focusedViewportID: focusedViewportID,
            viewOptions: viewports.mapValues(\.viewOptionsForStateRestoration),
            legacyDocumentOptions: nil,
            sidebarVisible: sidebarVisibility != .detailOnly,
            crossSections: viewports.mapValues(\.crossSections),
            measurements: measurements.restorableState
        )
    }

    /// Rebuilds the viewports and layout from a saved snapshot, replacing the initial single
    /// viewport. Applies each viewport's options now; if the model hasn't loaded yet, each
    /// viewport's `modelWasLoaded` sink builds its clone later (the restored camera is preserved).
    func restore(_ state: DocumentLayoutState) {
        guard let document, !state.layout.leafIDs.isEmpty else { return }

        for viewport in viewports.values { viewport.tearDown() }

        if let measurementState = state.measurements {
            measurements.loadRestorableState(measurementState)
        }

        var rebuilt: [UUID: ViewportController] = [:]
        for id in state.layout.leafIDs {
            let viewport = makeViewport(id: id, document: document)
            if let options = state.viewOptions[id] {
                viewport.setViewOptions(options)
            }
            // Saves from before smoothShading/edgeVisibility moved into per-viewport `ViewOptions`
            // carried one document-wide value instead; apply it to every restored viewport so
            // reopening an old document doesn't reset its shading/edge choice.
            if let legacy = state.legacyDocumentOptions {
                viewport.viewOptions.smoothShading = legacy.smoothShading
                viewport.viewOptions.edgeVisibility = legacy.edgeVisibility
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

        // Set `viewports` and the layout/focus that index into it together, before publishing `ratios`,
        // so a SwiftUI re-evaluation triggered mid-restore never sees them disagree.
        viewports = rebuilt
        layout = state.layout
        focusedViewportID = state.layout.leafIDs.contains(state.focusedViewportID)
            ? state.focusedViewportID : state.layout.leafIDs[0]
        ratios = state.ratios
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
    /// Present only in saves from before smoothShading/edgeVisibility moved into per-viewport
    /// `ViewOptions`; migrated onto every restored viewport in `restore(_:)`. Always `nil` going
    /// forward — `snapshot()` never writes it.
    var legacyDocumentOptions: LegacyDocumentViewOptions?
    /// Optional so documents saved before the sidebar existed still decode (treated as closed).
    var sidebarVisible: Bool?
    /// Per-viewport cross-section planes. Optional so documents saved before cross-sections decode.
    var crossSections: [UUID: [CrossSection]]?
    /// Document-global measurements. Optional so documents saved before measurements were persisted decode.
    var measurements: MeasurementController.RestorableState?
}

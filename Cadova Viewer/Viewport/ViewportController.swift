import SceneKit
import Foundation
import Combine
import AppKit
import NavLib
import simd
import ViewerCore
import Synchronization

class ViewportController: NSObject, ObservableObject, SCNSceneRendererDelegate {
    let sceneView = CustomSceneView(frame: .zero)
    let sceneController: SceneController
    /// This viewport's own scene. Each viewport renders an independent scene (its own real
    /// lighting, its own `isHidden` part visibility) built from the shared model data.
    let scene = SCNScene()
    var overlayScene: OverlayScene!

    weak var document: Document?

    /// This viewport's stable identity in the document's layout (its key in `DocumentViewModel`).
    let viewportID: UUID
    /// The owning view model, used by focus/split/close menu actions. Weak — the view model owns us.
    weak var documentViewModel: DocumentViewModel?
    /// Whether this is the document's focused viewport. Drives which NavLib (SpaceMouse) session is
    /// the active one, and the focus border.
    var isFocusedViewport = false

    /// The document-global measurement state, shared by every viewport.
    let measurementController: MeasurementController
    /// This viewport's drawing of those measurements, in its own scene.
    let measurementRenderer: MeasurementRenderer

    /// This viewport's private clone of the shared model (clone nodes living in `scene`). Rebuilt
    /// whenever the model loads; mediates per-viewport visibility, hit testing, and the document-
    /// global geometry options. See `ViewportModelInstance`.
    ///
    /// `SCNView` drives the `SCNSceneRendererDelegate` callbacks on its own render thread, which
    /// reads this, while the main thread reassigns it when the model loads. The `Mutex` makes that
    /// safe — without it, reassigning the node-bearing struct races ARC retain/release and corrupts
    /// the heap (surfacing as an unrelated `EXC_BAD_ACCESS`, e.g. in `swift_task_dealloc`).
    var modelInstance: ViewportModelInstance {
        get { _modelInstance.withLock { $0 } }
        set { _modelInstance.withLock { $0 = newValue } }
    }
    private let _modelInstance = Mutex<ViewportModelInstance>(ViewportModelInstance())

    /// Holds this viewport's chrome — grid, origin, measurements, highlight ghosts — under one node
    /// so it can be hidden when copying a no-background snapshot.
    let privateRoot = SCNNode()

    /// The translucent locator quad drawn at the cross-section plane. See
    /// `ViewportController+CrossSection`.
    let crossSectionPlaneNode = SCNNode()

    /// Holds the filled cap geometry drawn where each cut plane slices each part. Rebuilt off the main
    /// thread whenever a plane moves; see `ViewportController+CrossSection`.
    let crossSectionCapNode = SCNNode()
    /// The interactive transform handle for the selected cross-section.
    let crossSectionGizmo = CrossSectionGizmo()
    /// Whether a cap computation is currently running. Only one runs at a time; new requests during a
    /// drag set `crossSectionCapNeedsRebuild` instead of piling up a backlog of stale full scans.
    var crossSectionCapInFlight = false
    /// Set when a plane moved while a cap computation was in flight, so the latest is rebuilt once the
    /// current one finishes (a trailing update).
    var crossSectionCapNeedsRebuild = false
    /// Serialises the (potentially heavy) cap geometry computation off the main thread.
    let crossSectionCapQueue = DispatchQueue(label: "cross-section-cap", qos: .userInitiated)
    /// Persistent cap nodes and materials, keyed by section + part, reused across rebuilds so a drag
    /// only swaps geometry — avoiding per-frame material/shader-modifier recreation (which stutters).
    var crossSectionCapNodesByKey: [CrossSectionCapKey: SCNNode] = [:]
    var crossSectionCapMaterialsByKey: [CrossSectionCapKey: SCNMaterial] = [:]
    /// In-progress gizmo drag (handle grabbed + the section state when the drag began).
    var crossSectionDrag: CrossSectionDragState?
    /// Cross-sections as they were when a gizmo drag began, so the whole drag is one undo step.
    var crossSectionDragUndoSnapshot: [CrossSection]?
    /// Next palette colour index for a newly-added cross-section (mirrors measurement colouring).
    var nextCrossSectionColorIndex = 0

    /// The model's edge-line geometry nodes in this viewport's scene (depth offset + hit exclusion).
    var edgeNodes: [SCNNode] { modelInstance.edgeGeometryNodes }

    /// The scene view's current point size. Written on the main thread (the SwiftUI geometry
    /// callback) and read by the render-loop delegate, so it's guarded by a `Mutex`.
    var sceneViewSize: CGSize {
        get { _sceneViewSize.withLock { $0 } }
        set { _sceneViewSize.withLock { $0 = newValue } }
    }
    private let _sceneViewSize = Mutex<CGSize>(.zero)

    /// The active point-of-view node. Reassigned both on the render thread (SceneKit can swap the
    /// point of view in) and the main thread, and read from both, so it's guarded by a `Mutex`.
    var cameraNode: SCNNode {
        get { _cameraNode.withLock { $0 } }
        set { _cameraNode.withLock { $0 = newValue } }
    }
    private let _cameraNode = Mutex<SCNNode>(SCNNode())
    /// A directional "headlight" kept aimed along the camera's view direction. It lives on its own
    /// scene node (oriented each frame in `willRenderScene`) rather than being parented onto the
    /// point-of-view node — re-parenting a single light as SceneKit swaps point-of-view nodes could
    /// briefly leave it on two nodes, doubling the light and blowing out the model.
    let cameraLight = SCNLight()
    private let headlightNode = SCNNode()

    let grid: ViewportGrid
    @Published var viewOptions = Preferences().viewOptions {
        didSet {
            document?.invalidateRestorableState()
            // If the hovered part is toggled (e.g. clicked in the list), re-apply the highlight so
            // it follows the part across the visible↔hidden change — a hidden part keeps its
            // outline as a ghost. Done in didSet (not the $viewOptions sink) because @Published
            // emits in willSet, where self.hiddenPartIDs would still be the old value.
            if highlightedPartID != nil, viewOptions.hiddenPartIDs != oldValue.hiddenPartIDs {
                applyHighlight()
                sceneView.setNeedsRedraw()
            }
            // Caps cover only visible parts, so rebuild when visibility changes. Done here (didSet)
            // and not the $viewOptions sink for the same willSet reason: the sink would still see the
            // old `hiddenPartIDs`, building caps for exactly the wrong set of parts.
            if viewOptions.hiddenPartIDs != oldValue.hiddenPartIDs, !activeCrossSections.isEmpty {
                updateCrossSectionCap()
            }
        }
    }
    var hasSetInitialView = false

    /// Whether SpaceMouse-driven motion is currently suspended for this viewport (e.g. during a
    /// mouse drag or an animated fly-to). The document's NavLib session checks this on the focused
    /// viewport before applying motion.
    var navLibIsSuspended = false

    @Published var projection: CameraProjection = .perspective {
        didSet {
            if projection != oldValue {
                convertZoomForProjectionChange(to: projection)
            }
            updateCameraProjection()
        }
    }

    @Published var highlightedPartID: ModelData.Part.ID? {
        didSet { updateHighlightedPart(oldID: oldValue, newID: highlightedPartID) }
    }

    /// This viewport's cutting planes. Per-viewport (cuts in one split pane leave others intact),
    /// applied to this viewport's own materials. See `ViewportController+CrossSection`.
    @Published var crossSections: [CrossSection] = [] {
        didSet {
            guard crossSections != oldValue else { return }
            // Undo/redo (or delete) can drop the selected/hovered section — forget it so the gizmo and
            // plane don't reference a section that no longer exists.
            if let id = selectedCrossSectionID, !crossSections.contains(where: { $0.id == id }) {
                selectedCrossSectionID = nil
            }
            if let id = hoveredCrossSectionID, !crossSections.contains(where: { $0.id == id }) {
                hoveredCrossSectionID = nil
            }
            applyCrossSection()
            scheduleRestorableStateInvalidation() // coalesced — safe to hit per frame during a drag
        }
    }
    /// The cross-section being edited: shows its plane + gizmo and is the target of the popover.
    @Published var selectedCrossSectionID: UUID? {
        didSet { if selectedCrossSectionID != oldValue { updateCrossSectionOverlays() } }
    }
    /// A cross-section being hovered in the button row: previews its plane (no gizmo).
    @Published var hoveredCrossSectionID: UUID? {
        didSet { if hoveredCrossSectionID != oldValue { updateCrossSectionOverlays() } }
    }

    @Published private(set) var canResetCameraRoll: Bool = false
    @Published var canShowPresets: [ViewPreset: Bool] = [:]

    private let coordinateIndicatorValueStream = CurrentValueSubject<OrientationIndicatorValues, Never>(.init(x: .zero, y: .zero, z: .zero))
    var coordinateIndicatorValues: AnyPublisher<OrientationIndicatorValues, Never> { coordinateIndicatorValueStream.eraseToAnyPublisher() }

    var hoverPoint: CGPoint? {
        didSet { scheduleHoverPointUpdate() }
    }
    var hoverPointUpdateScheduled = false
    
    /// The geometry node currently named as the outline target, so its name can be cleared when
    /// the highlight moves. See `ViewportController+Highlight`.
    var outlineTargetNode: SCNNode?

    /// The faint ghost shown for a highlighted hidden part (its real geometry is invisible), kept
    /// so it can be torn down when the highlight moves.
    var highlightGhostNode: SCNNode?

    var observers: Set<AnyCancellable> = []

    // Backing storage for the measurement snap grid; the logic lives in
    // ViewportController+MeasurementInteraction (extensions can't hold stored properties).

    /// World-space corner vertices (endpoints of the model's sharp/feature edges) that
    /// the measurement tool can snap to when Option is held. Rebuilt on model load.
    var snapVertices: [SCNVector3] = []

    /// Screen-space bucket of `snapVertices` so hover lookups don't re-project every corner.
    /// Rebuilt only when the camera/viewport changes.
    var snapGridCells: [SIMD2<Int>: [(vertex: SCNVector3, screen: CGPoint)]] = [:]
    /// Must stay >= the snap threshold in `nearestSnapVertex`: the 3x3 cell search only finds
    /// vertices within one cell of the cursor.
    let snapGridCellSize = 44.0
    var snapGridWorldTransform = SCNMatrix4Identity
    var snapGridProjection = SCNMatrix4Identity
    var snapGridViewSize = CGSize.zero

    let showInfoCallbackSignals = PassthroughSubject<Void, Never>()
    var showInfoSignal: AnyPublisher<Void, Never> { showInfoCallbackSignals.eraseToAnyPublisher() }

    init(viewportID: UUID, document: Document, sceneController: SceneController, measurements: MeasurementController) {
        self.viewportID = viewportID
        self.sceneController = sceneController
        measurementController = measurements
        grid = ViewportGrid()
        let measurementParent = SCNNode()
        measurementParent.name = "Measurements"
        measurementRenderer = MeasurementRenderer(controller: measurements, parentNode: measurementParent, viewportID: viewportID)

        self.document = document
        super.init()

        // Assemble this viewport's own scene: shared image-based lighting, its chrome (grid +
        // measurements) under one hideable node, and an ambient fill. The model and the camera
        // headlight are added later (on load / below).
        scene.lightingEnvironment.contents = sceneController.skyboxImages
        privateRoot.name = "Viewport chrome"
        scene.rootNode.addChildNode(privateRoot)
        privateRoot.addChildNode(grid.node)
        privateRoot.addChildNode(measurementParent)
        crossSectionPlaneNode.name = "Cross-section plane"
        crossSectionPlaneNode.isHidden = true
        privateRoot.addChildNode(crossSectionPlaneNode)
        crossSectionCapNode.name = "Cross-section caps"
        privateRoot.addChildNode(crossSectionCapNode)
        privateRoot.addChildNode(crossSectionGizmo.root)

        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 30
        let ambientLightNode = SCNNode()
        ambientLightNode.name = "Ambient light"
        ambientLightNode.light = ambientLight
        scene.rootNode.addChildNode(ambientLightNode)

        sceneView.onClick = { [weak self] point in
            guard let self else { return }
            // A click off the gizmo (gizmo presses are intercepted earlier) exits cross-section edit
            // mode rather than placing a measurement.
            if selectedCrossSectionID != nil {
                selectedCrossSectionID = nil
                return
            }
            handleMeasurementClick(at: point)
        }
        sceneView.onHover = { [weak self] point in
            self?.hoverPoint = point
        }
        sceneView.onCancel = { [weak self] in
            self?.measurementController.cancelInProgress()
        }
        sceneView.beginGizmoDrag = { [weak self] point in
            self?.beginCrossSectionGizmoDrag(at: point) ?? false
        }
        sceneView.updateGizmoDrag = { [weak self] point in
            self?.updateCrossSectionGizmoDrag(at: point)
        }
        sceneView.endGizmoDrag = { [weak self] in
            self?.endCrossSectionGizmoDrag()
        }
        measurementRenderer.onVisualChange = { [weak self] in
            // The redraw drives updateAtTime → updateScreenSizes, which does the sizing.
            self?.sceneView.setNeedsRedraw()
        }

        overlayScene = OverlayScene(viewportController: self, renderer: sceneView)
        sceneView.overlaySKScene = overlayScene
        sceneView.viewportController = self

        sceneView.scene = scene
        sceneView.showsStatistics = false

        sceneView.mouseInteractionActive.sink { [weak self] active in
            guard let self else { return }
            setNavLibSuspended(active)

            if !active {
                viewDidChange()
            }
        }.store(in: &observers)


        sceneView.mouseRotationPivot.sink { [weak self] pivot in
            guard let self else { return }
            if let pivot {
                self.overlayScene.pivotPointLocation = pivot
            }
            self.overlayScene.pivotPointVisibility = pivot != nil
        }.store(in: &observers)

        sceneView.showContextMenu.receive(on: DispatchQueue.main).sink { [weak self] event in
            guard let self else { return }
            let viewPoint = sceneView.convert(event.locationInWindow, from: nil)
            NSMenu.popUpContextMenu(contextMenu(at: viewPoint), with: event, for: sceneView)
        }.store(in: &observers)

        let initialCamera = SCNCamera()
        let initialCameraNode = SCNNode()
        initialCameraNode.name = "Initial camera node"
        initialCameraNode.camera = initialCamera
        scene.rootNode.addChildNode(initialCameraNode)
        sceneView.pointOfView = initialCameraNode
        self.cameraNode = initialCameraNode

        sceneView.backgroundColor = NSColor(white: 0.05, alpha: 1)
        sceneView.allowsCameraControl = true
        sceneView.defaultCameraController.worldUp = SCNVector3(0, 0, 1)
        sceneView.defaultCameraController.automaticTarget = true
        sceneView.defaultCameraController.interactionMode = .orbitTurntable

        // A real directional headlight on its own node (oriented to the camera in willRenderScene).
        // This viewport renders its own scene, so the light affects only this viewport.
        sceneView.autoenablesDefaultLighting = false
        cameraLight.type = .directional
        cameraLight.intensity = 800
        headlightNode.name = "Headlight"
        headlightNode.light = cameraLight
        scene.rootNode.addChildNode(headlightNode)

        sceneView.delegate = self

        updateCameraProjection()

        sceneController.modelWasLoaded.sink { [weak self] in
            self?.applyLoadedModel()
        }.store(in: &observers)

        sceneController.documentGeometryChanged.sink { [weak self] in
            self?.applyDocumentOptions()
        }.store(in: &observers)

        $viewOptions.sink { [weak self] viewOptions in
            guard let self else { return }
            grid.showGrid = viewOptions.showGrid
            grid.showOrigin = viewOptions.showOrigin
            updatePartNodeVisibility(viewOptions.hiddenPartIDs)
            // Persist as the default for newly opened documents. Menu toggles only mutate
            // viewOptions (+ restorable state), which isn't reapplied on a manual reopen; this
            // keeps display options like smooth shading remembered. (setViewOptions does the
            // same on the restore path.)
            Preferences().viewOptions = viewOptions
        }.store(in: &observers)
    }

    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        grid.updateScale(renderer: sceneView, viewSize: sceneViewSize)
        measurementRenderer.updateScreenSizes(renderer: sceneView)

        // Track the active point-of-view node (SceneKit can swap it in). The headlight follows the
        // camera independently, in willRenderScene.
        if let currentCameraNode = sceneView.pointOfView, currentCameraNode != cameraNode {
            cameraNode = currentCameraNode
        }
    }

    func viewDidChange() {
        if cameraNode.camera == nil {
            return
        }
        // The camera transform is persisted only for state restoration; nothing reads the live
        // value. It's captured lazily from the camera node at save time (see
        // `viewOptionsForStateRestoration`) rather than written into the @Published `viewOptions`
        // here. Publishing it every navigation frame fired `objectWillChange` each frame — which the
        // view model re-broadcasts to the whole document UI — making per-frame SwiftUI re-evaluation
        // dominate main-thread time and stutter SpaceMouse navigation. So just flag the document
        // dirty (coalesced to one deferred call) so the new camera position is saved once motion
        // settles.
        scheduleRestorableStateInvalidation()

        // The toolbar's roll/preset enabled state isn't needed until navigation finishes, and
        // recomputing + publishing it every motion frame is wasteful (each publish repaints the
        // toolbar, and `canShowViewPreset` walks the model bounds). `viewDidChange` fires on each
        // `motionActiveChanged(false)`, which recurs throughout a continuous gesture, so debounce:
        // (re)arm a settle timer here and only refresh once motion has been quiet for a beat.
        scheduleNavigationSettledUpdate()
    }

    /// How long the camera must stay quiet after the last `viewDidChange` before the navigation-
    /// dependent toolbar state (`canResetCameraRoll`, `canShowPresets`) is refreshed.
    private static let navigationSettleDelay: TimeInterval = 0.25
    private var navigationSettleWorkItem: DispatchWorkItem?

    /// (Re)arms the settle timer. Each `viewDidChange` pushes it back, so the refresh lands only
    /// after motion stops; `motionActiveChanged(true)` cancels it when a new gesture begins.
    func scheduleNavigationSettledUpdate() {
        navigationSettleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateNavigationDependentState() }
        navigationSettleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.navigationSettleDelay, execute: work)
    }

    /// Cancels a pending settle refresh because navigation has resumed.
    func cancelNavigationSettledUpdate() {
        navigationSettleWorkItem?.cancel()
        navigationSettleWorkItem = nil
    }

    private func updateNavigationDependentState() {
        let canReset = canResetRoll()
        if canReset != canResetCameraRoll {
            canResetCameraRoll = canReset
        }

        let presetFlags = Dictionary(uniqueKeysWithValues: ViewPreset.allCases.map {
            ($0, canShowViewPreset($0))
        })
        if canShowPresets != presetFlags {
            canShowPresets = presetFlags
        }
    }

    func renderer(_ renderer: any SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        grid.updateVisibility(cameraNode: cameraNode)

        guard let pov = renderer.pointOfView?.presentation else { return }

        // Aim the headlight along the camera's view direction (both shine/look along their node's
        // -Z), so it reads as a light coming from the viewer.
        headlightNode.simdWorldOrientation = pov.simdWorldOrientation

        let indicatorValues = OrientationIndicatorValues(
            x: pov.convertVector(SCNVector3(1, 0, 0), from: nil),
            y: pov.convertVector(SCNVector3(0, 1, 0), from: nil),
            z: pov.convertVector(SCNVector3(0, 0, 1), from: nil)
        )

        coordinateIndicatorValueStream.send(indicatorValues)

        // Per frame: slide the gizmo to the view centre on its plane (using the live presentation
        // camera, `pov`, so it tracks during an orbit) and keep it a constant on-screen size.
        crossSectionGizmo.followView(presentationCamera: pov, isDragging: crossSectionDrag != nil)
        crossSectionGizmo.updateScreenScale(renderer: renderer)

        sceneView.applyEdgeDepthOffset(
            edgeNodes: modelInstance.edgeGeometryNodes,
            cameraNode: cameraNode,
            modelNode: modelInstance.root,
            viewSize: sceneViewSize
        )

        // Keep edge lines ~1pt wide regardless of the drawable's backing scale.
        let lineWidthInPoints = 1.0
        let scale = max(renderer.currentViewport.width / sceneViewSize.width, 1.0)
        if scale.isFinite {
            renderer.currentRenderCommandEncoder?.setLineWidthPrivate(Float(lineWidthInPoints * scale))
        }
    }

    func clearRoll() {
        setCameraView(clearRollView(), movement: .small)
    }

    /// (Re)builds this viewport's clone of the now-loaded model and runs the per-viewport setup
    /// that depends on it: swaps the clone into the scene, applies the document-global geometry
    /// options and this viewport's part visibility, fits the camera (first time only), sizes the
    /// grid, and gathers snap vertices. Called when the model loads and when a viewport is created
    /// by a split after the model is already loaded.
    func applyLoadedModel() {
        modelInstance.root.removeFromParentNode()
        modelInstance = ViewportModelInstance(modelData: sceneController.modelData)
        scene.rootNode.addChildNode(modelInstance.root)

        applyDocumentOptions()
        updatePartNodeVisibility(viewOptions.hiddenPartIDs)

        // Drop any cap nodes/materials from a previously-loaded model before rebuilding.
        crossSectionCapNode.childNodes.forEach { $0.removeFromParentNode() }
        crossSectionCapNodesByKey.removeAll()
        crossSectionCapMaterialsByKey.removeAll()
        installCrossSectionShader()
        applyModelClipUniforms() // clip in the first frame so a reload doesn't flash the whole model
        applyCrossSection()

        if !hasSetInitialView {
            showViewPreset(.isometric, animated: false)
            hasSetInitialView = true
        }

        grid.updateBounds(geometry: modelInstance.root)
        snapVertices = gatherSnapVertices()
        objectWillChange.send()
    }

    /// Applies the document-global geometry options (edge visibility, smooth shading) to this
    /// viewport's clone nodes. Smooth geometry is shared and built off the main thread by
    /// `SceneController`; until it's ready this falls back to flat and re-applies on the
    /// `documentGeometryChanged` signal.
    func applyDocumentOptions() {
        let options = sceneController.documentOptions
        for container in modelInstance.sharpEdgeContainers {
            container.isHidden = options.edgeVisibility == .none
        }
        for container in modelInstance.smoothEdgeContainers {
            container.isHidden = options.edgeVisibility != .all
        }
        for variant in modelInstance.variantSwaps {
            variant.apply(smoothShading: options.smoothShading)
        }
    }

    /// `viewOptions` with the live camera transform folded in, for state capture. The transform is
    /// deliberately kept out of the per-frame `@Published` path (see `viewDidChange`), so it's read
    /// straight from the camera node whenever the layout is actually snapshotted.
    var viewOptionsForStateRestoration: ViewOptions {
        var options = viewOptions
        options.cameraTransform = cameraNode.transform
        return options
    }

    /// Marks the document's restorable state dirty, coalescing the many per-frame requests during
    /// navigation into a single deferred call. Main-thread only (all `viewDidChange` callers are).
    private var restorableStateInvalidationScheduled = false
    private func scheduleRestorableStateInvalidation() {
        if restorableStateInvalidationScheduled { return }
        restorableStateInvalidationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            restorableStateInvalidationScheduled = false
            document?.invalidateRestorableState()
        }
    }

    func setViewOptions(_ viewOptions: ViewOptions) {
        self.viewOptions = viewOptions
        grid.showGrid = viewOptions.showGrid
        grid.showOrigin = viewOptions.showOrigin
        cameraNode.transform = viewOptions.cameraTransform
        updatePartNodeVisibility(viewOptions.hiddenPartIDs)
        hasSetInitialView = true
        Preferences().viewOptions = viewOptions
    }

    /// Makes this the document's focused viewport (menu/toolbar/NavLib commands act on it). Called
    /// when the scene view is clicked.
    func requestFocus() {
        documentViewModel?.focus(viewportID)
    }

    /// Releases the viewport before it's discarded (on close): stop NavLib motion and drop the
    /// notification/Combine subscriptions. The shared scene's private node is removed by the
    /// document view model. The controller then deallocates with its scene view and NavLib session.
    func tearDown() {
        setNavLibSuspended(true)
        observers.removeAll()
        // Undo actions strong-reference this controller as their target; drop a closed viewport's so
        // it isn't kept alive (and stale cross-section undos for it can't fire).
        document?.interactionUndoManager.removeAllActions(withTarget: self)
    }

    func showSceneKitRenderingOptions() {
        let panelClass: AnyObject? = NSClassFromString("SCNRendererOptionsPanel")
        let panel = panelClass?.perform(NSSelectorFromString("rendererOptionsPanelForView:"), with: sceneView).takeUnretainedValue() as? NSPanel
        panel?.hidesOnDeactivate = true
        panel?.isFloatingPanel = true
        panel?.makeKeyAndOrderFront(nil)
    }

}

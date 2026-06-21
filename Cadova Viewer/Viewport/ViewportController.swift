import SceneKit
import Foundation
import Combine
import AppKit
import NavLib
import simd
import ViewerCore
import Synchronization

class ViewportController: NSObject, ObservableObject {
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

    /// The latest SpaceMouse-commanded camera transform, handed from NavLib's setter (main thread,
    /// lock-free) to the render loop, which applies it. This keeps the setter from running an
    /// `SCNTransaction` commit — and taking the SceneKit scene lock — on every motion frame; that
    /// contention stalled the run loop and backed NavLib's frames up, so the model kept gliding after
    /// release. Applied in `renderer(_:updateAtTime:)`. See `ViewportController+SpaceMouse`.
    let pendingNavLibTransform = Mutex<SCNMatrix4?>(nil)

    /// A directional "headlight" kept aimed along the camera's view direction. It lives on its own
    /// scene node (oriented each frame in `willRenderScene`) rather than being parented onto the
    /// point-of-view node — re-parenting a single light as SceneKit swaps point-of-view nodes could
    /// briefly leave it on two nodes, doubling the light and blowing out the model.
    let cameraLight = SCNLight()
    let headlightNode = SCNNode()

    let grid: ViewportGrid
    /// The fixed world up axis for camera navigation (+Z). Used by the custom camera controller and
    /// by roll clearing.
    let worldUp = SCNVector3(0, 0, 1)
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
    /// How long the camera must stay quiet after the last `viewDidChange` before the navigation-
    /// dependent toolbar state (`canResetCameraRoll`, `canShowPresets`) is refreshed.
    static let navigationSettleDelay: TimeInterval = 0.25
    var navigationSettleWorkItem: DispatchWorkItem?
    var restorableStateInvalidationScheduled = false

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
            // Undo/redo (or delete) can drop the selected section — forget it so the gizmo and plane
            // don't reference a section that no longer exists.
            if let id = selectedCrossSectionID, !crossSections.contains(where: { $0.id == id }) {
                selectedCrossSectionID = nil
            }
            applyCrossSection()
            scheduleRestorableStateInvalidation() // coalesced — safe to hit per frame during a drag
        }
    }
    /// The cross-section being edited: shows its plane + gizmo and is the target of the popover.
    @Published var selectedCrossSectionID: UUID? {
        didSet { if selectedCrossSectionID != oldValue { updateCrossSectionOverlays() } }
    }

    @Published var canResetCameraRoll: Bool = false
    @Published var canShowPresets: [ViewPreset: Bool] = [:]

    let coordinateIndicatorValueStream = CurrentValueSubject<OrientationIndicatorValues, Never>(.init(x: .zero, y: .zero, z: .zero))
    var coordinateIndicatorValues: AnyPublisher<OrientationIndicatorValues, Never> { coordinateIndicatorValueStream.eraseToAnyPublisher() }

    /// Drives the on-screen grid scale legend. Pushed from the render delegate only when the spacing,
    /// fade, or visibility meaningfully changes, so it doesn't churn the UI every frame.
    let gridScaleStream = CurrentValueSubject<ViewportGrid.ScaleInfo, Never>(.init(coarseExponent: 0, isVisible: false))
    var gridScaleInfo: AnyPublisher<ViewportGrid.ScaleInfo, Never> { gridScaleStream.eraseToAnyPublisher() }
    var lastSentGridScale: ViewportGrid.ScaleInfo?

    var hoverPoint: CGPoint? {
        didSet {
            scheduleHoverPointUpdate()
            // The cursor moved, so the cached zoom-toward-cursor pivot is stale. (Scroll/pinch don't
            // move the cursor, so a zoom burst keeps reusing the one hit-test.)
            zoomPivot = nil
        }
    }
    var hoverPointUpdateScheduled = false

    /// Cached world pivot for zoom-toward-cursor, hit-tested once per cursor resting spot rather than
    /// every scroll/pinch event (which would re-scan the scene and drop the framerate). Cleared when
    /// the cursor moves. See `zoomCamera(factor:towardViewPoint:)`.
    var zoomPivot: SCNVector3?

    // Camera glide (post-release momentum). A high-frequency timer integrates `inertiaVelocity` into
    // `inertiaDelta` and re-applies the drag from its captured start. It ticks faster than the
    // display refreshes so every rendered frame samples a fresh pose (matching an active drag, which
    // updates at mouse-event rate) — a vsync-rate updater beats against SceneKit's render loop and
    // looks choppy. See `ViewportController+CameraInteraction`.
    var inertiaTimer: Timer?
    var inertiaDragState: CameraDragState?
    var inertiaDelta: SIMD2<Float> = .zero
    var inertiaVelocity: SIMD2<Float> = .zero
    var inertiaIsOrbit = false
    var inertiaLastTime: CFTimeInterval = 0
    
    /// The geometry node currently named as the outline target, so its name can be cleared when
    /// the highlight moves. See `ViewportController+Highlight`.
    var outlineTargetNode: SCNNode?

    /// The faint ghost shown for a highlighted hidden part (its real geometry is invisible), kept
    /// so it can be torn down when the highlight moves.
    var highlightGhostNode: SCNNode?

    var observers: Set<AnyCancellable> = []

    /// Local monitor for modifier-key (Shift) changes, so the cross-section gizmo can switch plane/world
    /// space regardless of which view has focus. Removed in `tearDown`.
    var modifierFlagsMonitor: Any?

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

        configureScene(measurementParent: measurementParent)
        configureSceneViewCallbacks()
        configureOverlayScene()
        configureSceneView()
        configureInitialCamera()
        configureHeadlight()
        bindSceneViewSignals()
        updateCameraProjection()
        bindModelSignals()
        bindViewOptions()
    }

}

import SceneKit
import Foundation
import Combine
import AppKit
import NavLib
import simd
import ViewerCore

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
    var modelInstance = ViewportModelInstance()

    /// Holds this viewport's chrome — grid, origin, measurements, highlight ghosts — under one node
    /// so it can be hidden when copying a no-background snapshot.
    let privateRoot = SCNNode()

    /// The model's edge-line geometry nodes in this viewport's scene (depth offset + hit exclusion).
    var edgeNodes: [SCNNode] { modelInstance.edgeGeometryNodes }

    var sceneViewSize: CGSize = .zero

    var cameraNode = SCNNode()
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

    @Published private(set) var canResetCameraRoll: Bool = false
    @Published var canShowPresets: [ViewPreset: Bool] = [:]

    private let coordinateIndicatorValueStream = CurrentValueSubject<OrientationIndicatorValues, Never>(.init(x: .zero, y: .zero, z: .zero))
    var coordinateIndicatorValues: AnyPublisher<OrientationIndicatorValues, Never> { coordinateIndicatorValueStream.eraseToAnyPublisher() }

    var hoverPoint: CGPoint? {
        didSet { hoverPointDidChange() }
    }
    
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
    let snapGridCellSize = 16.0
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
        measurementRenderer = MeasurementRenderer(controller: measurements, parentNode: measurementParent)

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

        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 30
        let ambientLightNode = SCNNode()
        ambientLightNode.name = "Ambient light"
        ambientLightNode.light = ambientLight
        scene.rootNode.addChildNode(ambientLightNode)

        sceneView.onClick = { [weak self] point in
            self?.handleMeasurementClick(at: point)
        }
        sceneView.onCancel = { [weak self] in
            self?.measurementController.cancelInProgress()
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
        // Defer the @Published write: this can be reached from a NavLib/scene-view callback that
        // runs inside a SwiftUI view update, and publishing there triggers "Publishing changes from
        // within view updates is not allowed." Nothing reads the live transform — it's only for
        // state restoration — so a runloop-turn's delay is fine.
        let transform = cameraNode.transform
        DispatchQueue.main.async { [weak self] in self?.viewOptions.cameraTransform = transform }

        let canReset = canResetRoll()
        if canReset != canResetCameraRoll {
            DispatchQueue.main.async { self.canResetCameraRoll = canReset }
        }

        let presetFlags = Dictionary(uniqueKeysWithValues: ViewPreset.allCases.map {
            ($0, canShowViewPreset($0))
        })
        if canShowPresets != presetFlags {
            DispatchQueue.main.async { self.canShowPresets = presetFlags }
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
        for (node, variant) in modelInstance.variantSwaps {
            node.geometry = options.smoothShading ? (variant.smoothIfAvailable ?? variant.flat) : variant.flat
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
    }

    func showSceneKitRenderingOptions() {
        let panelClass: AnyObject? = NSClassFromString("SCNRendererOptionsPanel")
        let panel = panelClass?.perform(NSSelectorFromString("rendererOptionsPanelForView:"), with: sceneView).takeUnretainedValue() as? NSPanel
        panel?.hidesOnDeactivate = true
        panel?.isFloatingPanel = true
        panel?.makeKeyAndOrderFront(nil)
    }

}

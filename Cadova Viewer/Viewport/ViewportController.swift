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
    var overlayScene: OverlayScene!

    weak var document: Document?

    let categoryID: Int
    let privateContainer: SCNNode
    let measurementController: MeasurementController

    var sceneViewSize: CGSize = .zero

    var cameraNode = SCNNode()
    let cameraLight = SCNLight()

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

    var navLibSession = NavLibSession<SCNVector3>()
    var navLibIsActive = false
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

    init(document: Document, sceneController: SceneController, categoryID: Int, privateContainer: SCNNode) {
        self.sceneController = sceneController
        self.categoryID = categoryID
        self.privateContainer = privateContainer
        grid = ViewportGrid(categoryID: categoryID)
        privateContainer.addChildNode(grid.node)
        measurementController = MeasurementController(
            parentNode: sceneController.viewportPrivateNode(for: categoryID),
            categoryID: categoryID
        )

        self.document = document
        super.init()

        sceneView.onClick = { [weak self] point in
            self?.handleMeasurementClick(at: point)
        }
        sceneView.onCancel = { [weak self] in
            self?.measurementController.cancelInProgress()
        }
        measurementController.onVisualChange = { [weak self] in
            // The redraw drives updateAtTime → updateScreenSizes, which does the sizing.
            self?.sceneView.setNeedsRedraw()
        }
        measurementController.undoManager = document.measurementUndoManager
        
        overlayScene = OverlayScene(viewportController: self, renderer: sceneView)
        sceneView.overlaySKScene = overlayScene
        sceneView.sceneController = sceneController

        sceneView.scene = sceneController.scene
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
        sceneController.scene.rootNode.addChildNode(initialCameraNode)
        sceneView.pointOfView = initialCameraNode
        self.cameraNode = initialCameraNode

        sceneView.backgroundColor = NSColor(white: 0.05, alpha: 1)
        sceneView.allowsCameraControl = true
        sceneView.defaultCameraController.worldUp = SCNVector3(0, 0, 1)
        sceneView.defaultCameraController.automaticTarget = true
        sceneView.defaultCameraController.interactionMode = .orbitTurntable

        sceneView.autoenablesDefaultLighting = false
        cameraLight.type = .directional
        cameraLight.intensity = 800
        cameraLight.categoryBitMask = 1 << categoryID
        cameraNode.light = cameraLight

        sceneView.delegate = self

        updateCameraProjection()

        sceneController.modelWasLoaded.sink { [weak self] in
            guard let self else { return }

            if !hasSetInitialView {
                showViewPreset(.isometric, animated: false)
                hasSetInitialView = true
            }

            grid.updateBounds(geometry: sceneController.modelContainer)
            snapVertices = gatherSnapVertices()
            setEdgeVisibilityInParts(viewOptions.edgeVisibility)
            setSmoothShadingInParts(viewOptions.smoothShading)
            updatePartNodeVisibility(viewOptions.hiddenPartIDs)
            objectWillChange.send()
        }.store(in: &observers)

        $viewOptions.sink { [weak self] viewOptions in
            guard let self else { return }
            setEdgeVisibilityInParts(viewOptions.edgeVisibility)
            setSmoothShadingInParts(viewOptions.smoothShading)
            grid.showGrid = viewOptions.showGrid
            grid.showOrigin = viewOptions.showOrigin
            updatePartNodeVisibility(viewOptions.hiddenPartIDs)
            // Persist as the default for newly opened documents. Menu toggles only mutate
            // viewOptions (+ restorable state), which isn't reapplied on a manual reopen; this
            // keeps display options like smooth shading remembered. (setViewOptions does the
            // same on the restore path.)
            Preferences().viewOptions = viewOptions
        }.store(in: &observers)

        cameraNodeChanged(cameraNode)
        startNavLib()
    }

    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        grid.updateScale(renderer: sceneView, viewSize: sceneViewSize)
        measurementController.updateScreenSizes(renderer: sceneView)

        if let currentCameraNode = sceneView.pointOfView, currentCameraNode != cameraNode {
            cameraNodeChanged(currentCameraNode)
        }
    }

    private func cameraNodeChanged(_ newCameraNode: SCNNode) {
        cameraNode.light = nil
        cameraNode = newCameraNode
        newCameraNode.light = cameraLight

        cameraNode.camera?.categoryBitMask = GlobalCategoryMasks.universal.rawValue | (1 << categoryID)
    }

    func viewDidChange() {
        if cameraNode.camera == nil {
            return
        }
        viewOptions.cameraTransform = cameraNode.transform

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

        let indicatorValues = OrientationIndicatorValues(
            x: pov.convertVector(SCNVector3(1, 0, 0), from: nil),
            y: pov.convertVector(SCNVector3(0, 1, 0), from: nil),
            z: pov.convertVector(SCNVector3(0, 0, 1), from: nil)
        )

        coordinateIndicatorValueStream.send(indicatorValues)

        sceneView.applyEdgeDepthOffset(
            edgeNodes: sceneController.edgeNodes,
            cameraNode: cameraNode,
            modelNode: sceneController.modelContainer,
            viewSize: sceneViewSize
        )

        // Keep edge lines ~1pt wide regardless of the drawable's backing scale.
        let lineWidthInPoints = 1.0
        let scale = max(renderer.currentViewport.width / sceneViewSize.width, 1.0)
        renderer.currentRenderCommandEncoder?.setLineWidthPrivate(Float(lineWidthInPoints * scale))
    }

    func clearRoll() {
        setCameraView(clearRollView(), movement: .small)
    }

    func setViewOptions(_ viewOptions: ViewOptions) {
        self.viewOptions = viewOptions
        grid.showGrid = viewOptions.showGrid
        grid.showOrigin = viewOptions.showOrigin
        cameraNode.transform = viewOptions.cameraTransform
        setEdgeVisibilityInParts(viewOptions.edgeVisibility)
        setSmoothShadingInParts(viewOptions.smoothShading)
        updatePartNodeVisibility(viewOptions.hiddenPartIDs)
        hasSetInitialView = true
        Preferences().viewOptions = viewOptions
    }

    func showSceneKitRenderingOptions() {
        let panelClass: AnyObject? = NSClassFromString("SCNRendererOptionsPanel")
        let panel = panelClass?.perform(NSSelectorFromString("rendererOptionsPanelForView:"), with: sceneView).takeUnretainedValue() as? NSPanel
        panel?.hidesOnDeactivate = true
        panel?.isFloatingPanel = true
        panel?.makeKeyAndOrderFront(nil)
    }

}

import SceneKit
import Foundation
import Combine
import AppKit
import NavLib
import simd

class ViewportController: NSObject, ObservableObject, SCNSceneRendererDelegate {
    let sceneView = CustomSceneView(frame: .zero)
    let sceneController: SceneController
    var overlayScene: OverlayScene!

    weak var document: Document?

    let categoryID: Int
    let privateContainer: SCNNode

    var sceneViewSize: CGSize = .zero

    var cameraNode = SCNNode()
    let cameraLight = SCNLight()

    let grid: ViewportGrid
    @Published var viewOptions = Preferences().viewOptions {
        didSet {
            document?.invalidateRestorableState()
        }
    }
    var hasSetInitialView = false

    var navLibSession = NavLibSession<SCNVector3>()
    var navLibIsActive = false
    var navLibIsSuspended = false

    @Published var projection: CameraProjection = .perspective {
        didSet { updateCameraProjection() }
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
    
    var highlightNode: SCNNode?
    var observers: Set<AnyCancellable> = []

    let showInfoCallbackSignals = PassthroughSubject<Void, Never>()
    var showInfoSignal: AnyPublisher<Void, Never> { showInfoCallbackSignals.eraseToAnyPublisher() }

    init(document: Document, sceneController: SceneController, categoryID: Int, privateContainer: SCNNode) {
        self.sceneController = sceneController
        self.categoryID = categoryID
        self.privateContainer = privateContainer
        grid = ViewportGrid(categoryID: categoryID)
        privateContainer.addChildNode(grid.node)

        self.document = document
        super.init()
        
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
            NSMenu.popUpContextMenu(contextMenu(), with: event, for: self.sceneView)
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
            setEdgeVisibilityInParts(viewOptions.edgeVisibility)
            updatePartNodeVisibility(viewOptions.hiddenPartIDs)
            objectWillChange.send()
        }.store(in: &observers)

        $viewOptions.sink { [weak self] viewOptions in
            guard let self else { return }
            setEdgeVisibilityInParts(viewOptions.edgeVisibility)
            grid.showGrid = viewOptions.showGrid
            grid.showOrigin = viewOptions.showOrigin
            updatePartNodeVisibility(viewOptions.hiddenPartIDs)
        }.store(in: &observers)

        cameraNodeChanged(cameraNode)
        startNavLib()
    }

    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        grid.updateScale(renderer: sceneView, viewSize: sceneViewSize)

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

        // Calculate a suitable distance for offsetting edges
        let localHitTestPoints: [CGPoint] = [
            CGPoint(x: sceneViewSize.width / 2, y: sceneViewSize.height / 2),
            CGPoint(x: 0, y: 0),
            CGPoint(x: sceneViewSize.width, y: 0),
            CGPoint(x: sceneViewSize.width, y: sceneViewSize.height),
            CGPoint(x: 0, y: sceneViewSize.height),
        ]

        var closestHitTestDistance: Float = 1000.0
        for viewPoint in localHitTestPoints {
            let hitTestResult = sceneView.hitTest(viewPoint, options: [
                .searchMode: SCNHitTestSearchMode.all.rawValue as NSNumber,
                .rootNode: sceneController.modelContainer
            ]).first(where: { $0.node.name != "edges" })

            if let hitTestResult {
                closestHitTestDistance = min(Float(hitTestResult.worldCoordinates.distance(from: cameraNode.presentation.worldPosition)), closestHitTestDistance)
            }
        }

        let edgeNodes = sceneController.modelContainer.childNodes(passingTest: { node, _ in node.name == "edges" })
        for node in edgeNodes {
            node.simdPosition = .zero
            let distanceToPart = Float(cameraNode.presentation.worldPosition.distance(from: node.worldPosition))
            let minDistance = min(closestHitTestDistance, distanceToPart)
            let offset = minDistance / -1000.0
            //print(minDistance, offset)
            node.simdWorldPosition += cameraNode.presentation.simdWorldFront * offset
        }


        let encoder = renderer.currentRenderCommandEncoder as! NSObject
        if encoder.responds(to: NSSelectorFromString("setLineWidth:")) {
            let lineWidthInPoints = 1.0
            let scale = max(renderer.currentViewport.width / sceneViewSize.width, 1.0)
            encoder.setValue(lineWidthInPoints * scale, forKey: "lineWidth")
        }
    }

    func calculateOrthographicScale() -> Double {
        guard let cameraNode = sceneView.pointOfView,
              let camera = sceneView.pointOfView?.camera else { return 100.0 }

        let center = sceneController.modelContainer.boundingSphere.center
        let distance = cameraNode.position.distance(from: center)
        let fovRadians = camera.fieldOfView * (.pi / 180.0)
        let scale = distance * tan(fovRadians / 2.0)

        return scale
    }

    func updateCameraProjection() {
        guard let pov = sceneView.pointOfView,
              let camera = pov.camera else {
            return
        }

        if projection == .orthographic {
            camera.orthographicScale = calculateOrthographicScale()
            camera.usesOrthographicProjection = true
            camera.automaticallyAdjustsZRange = false
            camera.zNear = -100000
            camera.zFar = 100000
        } else {
            camera.usesOrthographicProjection = false
            camera.automaticallyAdjustsZRange = true
            camera.fieldOfView = 30
        }

        updateNavLibProjection()
    }

    func clearRoll() {
        setCameraView(clearRollView(), movement: .small)
    }

    private func hoverPointDidChange() {
        sceneView.render()
        updateNavLibPointerPosition()
    }

    func setViewOptions(_ viewOptions: ViewOptions) {
        self.viewOptions = viewOptions
        grid.showGrid = viewOptions.showGrid
        grid.showOrigin = viewOptions.showOrigin
        cameraNode.transform = viewOptions.cameraTransform
        setEdgeVisibilityInParts(viewOptions.edgeVisibility)
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

    enum CameraProjection {
        case orthographic
        case perspective
    }
}

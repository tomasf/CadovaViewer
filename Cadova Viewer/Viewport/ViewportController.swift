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

    var notificationTokens: [any NSObjectProtocol] = []
    var navLibIsSuspended = false

    @Published var projection: CameraProjection = .perspective {
        didSet { updateCameraProjection() }
    }

    // Parts
    @Published var hiddenPartIDs: Set<ModelData.Part.ID> = [] {
        didSet { updatePartNodeVisibility() }
    }

    var highlightNode: SCNNode?
    var savedMaterials: [SCNMaterial] = []
    @Published var highlightedPartID: ModelData.Part.ID? {
        didSet {
            updateHighlightedPart(oldID: oldValue, newID: highlightedPartID)
        }
    }

    @Published private(set) var canResetCameraRoll: Bool = false
    @Published var canShowPresets: [ViewPreset: Bool] = [:]

    var isAnimatingView = false

    private let coordinateIndicatorValueStream = CurrentValueSubject<OrientationIndicatorValues, Never>(.init(x: .zero, y: .zero, z: .zero))
    var coordinateIndicatorValues: AnyPublisher<OrientationIndicatorValues, Never> { coordinateIndicatorValueStream.eraseToAnyPublisher() }

    var hoverPoint: CGPoint? {
        didSet { hoverPointDidChange() }
    }

    var observers: Set<AnyCancellable> = []

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
            let offset = minDistance / -5000.0
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

    func showViewPreset(_ preset: ViewPreset, animated: Bool) {
        setCameraView(cameraView(for: preset), movement: animated ? .large : .instant)
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
        Preferences().viewOptions = viewOptions
        cameraNode.transform = viewOptions.cameraTransform
        hasSetInitialView = true
    }

    private func contextMenu() -> NSMenu {
        let builder = MenuBuilder()
        if sceneController.parts.count > 1 {
            builder.addHeader("Parts")

            for part in self.sceneController.parts {
                builder.addItem(label: part.displayName, checked: self.hiddenPartIDs.contains(part.id) == false) {
                    self.hiddenPartIDs.formSymmetricDifference([part.id])
                } onHighlight: { h in
                    self.highlightedPartID = h ? part.id : nil
                }

                builder.addItem(label: "Show only \"\(part.displayName)\"", alternateForModifiers: .option) {
                    self.hiddenPartIDs = Set(self.sceneController.parts.map(\.id)).subtracting([part.id])
                } onHighlight: { h in
                    self.highlightedPartID = h ? part.id : nil
                }
            }

            builder.addSeparator()
            if self.hiddenPartIDs.isEmpty {
                builder.addItem(label: "Hide All") {
                    self.hiddenPartIDs = Set(self.sceneController.parts.map(\.id))
                }
            } else {
                builder.addItem(label: "Show All") {
                    self.hiddenPartIDs = []
                }
            }
            builder.addSeparator()
        }

        builder.addItem(label: "Show Grid", checked: viewOptions.showGrid) {
            self.viewOptions.showGrid = !self.viewOptions.showGrid
        }

        builder.addItem(label: "Show Origin", checked: viewOptions.showOrigin) {
            self.viewOptions.showOrigin = !self.viewOptions.showOrigin
        }

        builder.addItem(label: "Show Axis Directions", checked: viewOptions.showCoordinateSystemIndicator) {
            self.viewOptions.showCoordinateSystemIndicator = !self.viewOptions.showCoordinateSystemIndicator
        }

        return builder.makeMenu()
    }

    func performMenuCommand(_ command: MenuCommand, tag: Int) {
        switch command {
        case .showViewPreset:
            guard let preset = ViewPreset(rawValue: tag) else {
                preconditionFailure("Invalid preset index")
            }
            showViewPreset(preset, animated: true)
        case .zoomIn:
            zoomIn()
        case .zoomOut:
            zoomOut()
        case .showRenderingOptions:
            let panelClass: AnyObject? = NSClassFromString("SCNRendererOptionsPanel")
            let panel = panelClass?.perform(NSSelectorFromString("rendererOptionsPanelForView:"), with: sceneView).takeUnretainedValue() as? NSPanel
            panel?.hidesOnDeactivate = true
            panel?.isFloatingPanel = true
            panel?.makeKeyAndOrderFront(nil)
        case .clearRoll:
            clearRoll()
        }
    }

    func canPerformMenuCommand(_ command: MenuCommand, tag: Int) -> Bool {
        switch command {
        case .showViewPreset:
            guard let preset = ViewPreset(rawValue: tag) else {
                preconditionFailure("Invalid preset index")
            }
            return canShowViewPreset(preset)
        case .clearRoll:
            return canResetRoll()
        default:
            return true
        }
    }

    enum CameraProjection {
        case orthographic
        case perspective
    }

    enum ViewPreset: Int, CaseIterable {
        case isometric
        case front
        case back
        case left
        case right
        case top
        case bottom
    }

    enum MenuCommand: String {
        case showViewPreset
        case zoomIn
        case zoomOut
        case showRenderingOptions
        case clearRoll
    }

    struct ViewOptions: Codable {
        var showGrid = true
        var showOrigin = true
        var showCoordinateSystemIndicator = true
        var cameraTransform: SCNMatrix4 = SCNMatrix4Identity

        enum CodingKeys: String, CodingKey {
            case showGrid
            case showOrigin
            case showCoordinateSystemIndicator
            case cameraTransform
        }

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            showGrid = try container.decode(Bool.self, forKey: .showGrid)
            showOrigin = try container.decode(Bool.self, forKey: .showOrigin)
            showCoordinateSystemIndicator = try container.decode(Bool.self, forKey: .showCoordinateSystemIndicator)
            cameraTransform = try container.decode(SCNMatrix4.CodingWrapper.self, forKey: .cameraTransform).scnMatrix4
        }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(showGrid, forKey: .showGrid)
            try container.encode(showOrigin, forKey: .showOrigin)
            try container.encode(showCoordinateSystemIndicator, forKey: .showCoordinateSystemIndicator)
            try container.encode(SCNMatrix4.CodingWrapper(cameraTransform), forKey: .cameraTransform)
        }
    }
}

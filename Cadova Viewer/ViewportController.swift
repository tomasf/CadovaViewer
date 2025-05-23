import SceneKit
import Foundation
import Combine
import AppKit
import NavLib

struct OrientationIndicatorValues {
    let x: CGPoint
    let y: CGPoint
    let z: CGPoint

    init(x: CGPoint, y: CGPoint, z: CGPoint) {
        self.x = x
        self.y = y
        self.z = z
    }

    init(x: SCNVector3, y: SCNVector3, z: SCNVector3) {
        self.x = CGPoint(x: x.x, y: x.y)
        self.y = CGPoint(x: y.x, y: y.y)
        self.z = CGPoint(x: z.x, y: z.y)
    }
}

struct MeasurementIndicator: Identifiable {
    let measurement: Measurement
    let fromPoint: Point
    let toPoint: Point

    struct Point {
        let point: CGPoint
        let visible: Bool
    }

    var id: Int { measurement.id }
}

enum InteractionMode {
    case view
    case measurement (MeasurementState)

    enum MeasurementState {
        case initial
        case selectingStart (id: Int)
        case selectingEnd (id: Int)
    }
}

class ViewportController: NSObject, ObservableObject, SCNSceneRendererDelegate {
    let sceneView = CustomSceneView(frame: .zero)
    let sceneController: SceneController

    weak var document: Document?

    let categoryID: Int
    let privateContainer: SCNNode

    var interactionMode: InteractionMode = .view //.measurement(.initial)

    var sceneViewSize: CGSize = .zero

    var cameraNode = SCNNode()
    let cameraLight = SCNLight()

    let grid: ViewportGrid

    var observers: Set<AnyCancellable> = []

    var session = NavLibSession()

    var notificationTokens: [any NSObjectProtocol] = []
    var navLibIsSuspended = false

    let debugSphere = SCNNode(geometry: SCNSphere(radius: 1))

    @Published var projection: CameraProjection = .perspective {
        didSet { updateCameraProjection() }
    }

    @Published var hiddenPartIDs: Set<ModelData.Part.ID> = [] {
        didSet { updatePartNodeVisibility() }
    }

    @Published private(set) var canResetCameraRoll: Bool = false
    @Published var canShowPresets: [ViewPreset: Bool] = [:]

    private let measurementsStream = CurrentValueSubject<[Measurement], Never>([])
    var measurements: AnyPublisher<[Measurement], Never> { measurementsStream.eraseToAnyPublisher() }

    var isAnimatingView = false

    private func updatePartNodeVisibility() {
        for part in sceneController.parts {
            if hiddenPartIDs.contains(part.id) {
                part.node.categoryBitMask &= ~(1 << categoryID)
            } else {
                part.node.categoryBitMask |= 1 << categoryID
            }
        }
    }

    private let coordinateIndicatorValueStream = CurrentValueSubject<OrientationIndicatorValues, Never>(.init(x: .zero, y: .zero, z: .zero))
    var coordinateIndicatorValues: AnyPublisher<OrientationIndicatorValues, Never> { coordinateIndicatorValueStream.eraseToAnyPublisher() }

    var pivotPoint: (location: SCNVector3, visible: Bool) = (.init(), false)

    var hoverPoint: CGPoint? {
        didSet { hoverPointDidChange() }
    }

    func removeMeasurement(id: Int) {
        measurementsStream.value.removeAll(where: { $0.id == id })
        if case .measurement (let state) = interactionMode {
            if case .selectingStart(let measurementID) = state, measurementID == id {
                interactionMode = .measurement(.initial)
            } else if case .selectingEnd(let measurementID) = state, measurementID == id {
                interactionMode = .measurement(.initial)
            }
        }
    }

    init(document: Document, sceneController: SceneController, categoryID: Int, privateContainer: SCNNode) {
        self.sceneController = sceneController
        self.categoryID = categoryID
        self.privateContainer = privateContainer
        grid = ViewportGrid(container: privateContainer, categoryID: categoryID)

        self.document = document
        super.init()

        sceneView.scene = sceneController.scene
        sceneView.showsStatistics = false

        sceneView.onClick = { [weak self] p in
            self?.handleClick(at: p)
        }

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
            self?.showViewPreset(.isometric, animated: false)
        }.store(in: &observers)

        cameraNodeChanged(cameraNode)
        startNavLib()

        sceneView.overlaySKScene = OverlayScene(viewportController: self, renderer: sceneView)

        /*
         measurementsStream.value = [
         Measurement(id: 0, fromPoint: .init(x: 0, y: 10, z: 0), toPoint: .init(14, 8, 25)),
         Measurement(id: 1, fromPoint: .init(x: 20, y: 2, z: 30))
         ]
         */
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

    func renderer(_ renderer: any SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        grid.updateVisibility(cameraNode: cameraNode)

        guard let pov = renderer.pointOfView?.presentation else { return }

        let indicatorValues = OrientationIndicatorValues(
            x: pov.convertVector(SCNVector3(1, 0, 0), from: nil),
            y: pov.convertVector(SCNVector3(0, 1, 0), from: nil),
            z: pov.convertVector(SCNVector3(0, 0, 1), from: nil)
        )

        coordinateIndicatorValueStream.send(indicatorValues)

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

        let edgeNodes = sceneController.modelContainer.childNodes(passingTest: { node, _ in node.name == "edges" })
        let globalOffset = cameraNode.presentation.simdWorldFront * -0.01

        for node in edgeNodes {
            node.simdPosition = .zero
            node.simdWorldPosition += globalOffset
        }

        
        let encoder = renderer.currentRenderCommandEncoder as! NSObject
        if encoder.responds(to: NSSelectorFromString("setLineWidth:")) {
            let lineWidthInPoints = 1.0
            let scale = max(renderer.currentViewport.width / sceneViewSize.width, 1.0)
            encoder.setValue(lineWidthInPoints * scale, forKey: "lineWidth")
        }

        recalculateHover()
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

    private func handleClick(at point: CGPoint) {
        switch interactionMode {
        case .view:
            break

        case .measurement(let measurementState):
            switch measurementState {
            case .initial: break
            case .selectingStart (let measurementID):
                interactionMode = .measurement(.selectingEnd(id: measurementID))

            case .selectingEnd:
                interactionMode = .measurement(.initial)
            }
        }
    }

    private func recalculateHover() {
        var measurements = measurementsStream.value

        switch interactionMode {
        case .view:
            break

        case .measurement (let measurementState):
            let matchPoint = hoverPoint.flatMap {
                var localPoint = $0
                localPoint.y = sceneViewSize.height - localPoint.y
                return sceneView.hitTest(localPoint, options: [
                    .categoryBitMask: (1 << categoryID) as NSNumber,
                    .rootNode: sceneController.modelContainer,
                    .searchMode: SCNHitTestSearchMode.closest.rawValue as NSNumber
                ]).first?.worldCoordinates
            }

            switch measurementState {
            case .initial:
                guard let matchPoint else { return }

                let nextID = (measurements.map(\.id).max() ?? -1) + 1
                let measurement = Measurement(id: nextID, fromPoint: matchPoint)
                measurements.append(measurement)
                interactionMode = .measurement(.selectingStart(id: nextID))

            case .selectingStart (let measurementID):
                guard let matchPoint else {
                    measurements.removeAll(where: { $0.id == measurementID })
                    interactionMode = .measurement(.initial)
                    break
                }

                guard let index = measurementsStream.value.firstIndex(where: { $0.id == measurementID }) else { break }
                measurements[index].fromPoint = matchPoint

            case .selectingEnd (let measurementID):
                guard let index = measurementsStream.value.firstIndex(where: { $0.id == measurementID }) else { break }

                guard let matchPoint else {
                    break
                }

                measurements[index].toPoint = matchPoint
            }
        }

        if measurements != measurementsStream.value {
            measurementsStream.value = measurements
        }
    }

    private func hoverPointDidChange() {
        sceneView.render()
        updateNavLibPointerPosition()
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
}

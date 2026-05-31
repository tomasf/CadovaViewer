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
        // Update measurement geometry before rendering so the per-frame screen-size
        // scaling in updateAtTime applies to the freshly placed/moved dots.
        if measurementController.interactionMode == .measure {
            let worldPoint = hoverPoint.flatMap { measurementPoint(atViewPoint: $0, flipY: true) }
            measurementController.hover(at: worldPoint)
            measurementController.updateScreenSizes(renderer: sceneView)
        }

        sceneView.render()
        updateNavLibPointerPosition()
    }

    private func handleMeasurementClick(at point: CGPoint) {
        guard measurementController.interactionMode == .measure else { return }
        if let worldPoint = measurementPoint(atViewPoint: point, flipY: false) {
            measurementController.commitPoint(at: worldPoint)
            measurementController.updateScreenSizes(renderer: sceneView)
            sceneView.render()
        }
    }

    /// The world point for the measurement under the cursor. With Shift held while a
    /// length measurement is in progress, the point is constrained to an axis through the
    /// start point (projected from the cursor ray, so it needn't lie on the model);
    /// otherwise it's the model surface hit (nil if the cursor misses the model).
    private func measurementPoint(atViewPoint point: CGPoint, flipY: Bool) -> SCNVector3? {
        if NSEvent.modifierFlags.contains(.shift), let start = measurementController.inProgressStart {
            return axisConstrainedPoint(atViewPoint: point, flipY: flipY, from: start)
        }
        return surfaceWorldPoint(atViewPoint: point, flipY: flipY)
    }

    /// Projects the cursor ray onto an axis line through `start`, choosing the axis whose
    /// screen-space direction best matches the cursor's movement from the start point.
    private func axisConstrainedPoint(atViewPoint point: CGPoint, flipY: Bool, from start: SCNVector3) -> SCNVector3? {
        let viewPoint = flipY ? CGPoint(x: point.x, y: sceneViewSize.height - point.y) : point

        let startScreen = sceneView.projectPoint(start)
        let screenDelta = simd_double2(Double(viewPoint.x) - Double(startScreen.x), Double(viewPoint.y) - Double(startScreen.y))
        guard simd_length(screenDelta) > 1e-3 else { return start }
        let screenDirection = simd_normalize(screenDelta)

        let startVector = simd_double3(Double(start.x), Double(start.y), Double(start.z))
        let axes: [simd_double3] = [simd_double3(1, 0, 0), simd_double3(0, 1, 0), simd_double3(0, 0, 1)]

        var bestAxis = axes[0]
        var bestScore = -1.0
        for axis in axes {
            let tip = sceneView.projectPoint(SCNVector3(startVector.x + axis.x, startVector.y + axis.y, startVector.z + axis.z))
            let direction = simd_double2(Double(tip.x) - Double(startScreen.x), Double(tip.y) - Double(startScreen.y))
            let length = simd_length(direction)
            guard length > 1e-6 else { continue } // axis points (almost) straight at the camera
            let score = abs(simd_dot(screenDirection, direction / length))
            if score > bestScore {
                bestScore = score
                bestAxis = axis
            }
        }

        // Closest point on the axis line (startVector, bestAxis) to the cursor ray.
        let nearPoint = sceneView.unprojectPoint(SCNVector3(viewPoint.x, viewPoint.y, 0))
        let farPoint = sceneView.unprojectPoint(SCNVector3(viewPoint.x, viewPoint.y, 1))
        let near = simd_double3(Double(nearPoint.x), Double(nearPoint.y), Double(nearPoint.z))
        let rayDirection = simd_double3(Double(farPoint.x), Double(farPoint.y), Double(farPoint.z)) - near
        let offset = startVector - near
        let b = simd_dot(bestAxis, rayDirection)
        let c = simd_dot(rayDirection, rayDirection)
        let denominator = c - b * b // bestAxis·bestAxis == 1
        guard abs(denominator) > 1e-9 else { return nil } // ray parallel to the axis
        let t = (b * simd_dot(rayDirection, offset) - c * simd_dot(bestAxis, offset)) / denominator
        let end = startVector + t * bestAxis
        return SCNVector3(end.x, end.y, end.z)
    }

    /// Casts a ray at the given view point and returns the world coordinates of the
    /// nearest model surface hit, or nil if the ray misses the model. `flipY` should
    /// be true for SwiftUI (top-left origin) points such as `hoverPoint`, and false
    /// for AppKit view-space points such as gesture recognizer locations.
    private func surfaceWorldPoint(atViewPoint point: CGPoint, flipY: Bool) -> SCNVector3? {
        let viewPoint = flipY ? CGPoint(x: point.x, y: sceneViewSize.height - point.y) : point
        let edgeNodes = sceneController.edgeNodes
        return sceneView.hitTest(viewPoint, options: [
            .searchMode: SCNHitTestSearchMode.all.rawValue as NSNumber,
            .rootNode: sceneController.modelContainer
        ]).first(where: { !edgeNodes.contains($0.node) })?.worldCoordinates
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

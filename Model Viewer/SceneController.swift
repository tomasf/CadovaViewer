import SceneKit
import Foundation
import Combine
import AppKit
import NavLibSwift

class SceneController: NSObject, ObservableObject, SCNSceneRendererDelegate {
    let sceneView = CustomSceneView()
    weak var document: Document?

    var sceneViewBounds: CGRect = .zero

    let modelContainer = SCNNode()
    let coarseGrid = SCNNode()
    let fineGrid = SCNNode()
    let gridContainer = SCNNode()
    let gridCover = SCNNode()

    var cameraNode = SCNNode()
    let cameraLight = SCNLight()

    let backgroundColor = NSColor(white: 0.05, alpha: 1)

    var observers: Set<AnyCancellable> = []

    var session = NavLibSession()

    let pivotMarker = CALayer()
    var pivotPoint = SCNVector3Zero
    var showPivotMarker = false
    var notificationTokens: [any NSObjectProtocol] = []
    var navLibIsSuspended = false

    let debugSphere = SCNNode(geometry: SCNSphere(radius: 1))

    @Published var projection: CameraProjection = .perspective
    @Published var interactionMode: SCNInteractionMode = .orbitTurntable
    @Published var parts: [ModelData.Part] = []

    var hoverPoint: CGPoint? {
        didSet {
            updateNavLibPointerPosition()
        }
    }

    @Published var canResetRoll: Bool = false

    var useNormals: Bool = false {
        didSet {
            reloadNormalsState()
        }
    }
    private var normalsCache: [String: SCNGeometrySource] = [:]

    init(modelStream: Document.ModelStream, document: Document) {
        super.init()
        self.document = document

        let scene = SCNScene()
        sceneView.scene = scene

        let names = ["right", "left", "front", "back", "bottom", "top"]
        let images = names.map { NSImage(named: "skybox3/\($0)")! }

        //scene.lightingEnvironment.contents = images
        //scene.background.contents = images
        //scene.background.contents = NSImage(named: "entrance_hall_4k")
        //scene.background.contentsTransform = SCNMatrix4MakeRotation(.pi / 2, 1, 0, 0)

        pivotMarker.bounds.size = CGSize(width: 10, height: 10)
        pivotMarker.cornerRadius = 5
        pivotMarker.backgroundColor = NSColor.red.withAlphaComponent(0.7).cgColor
        pivotMarker.borderColor = NSColor.black.cgColor
        pivotMarker.borderWidth = 1
        pivotMarker.opacity = 0
        sceneView.layer?.addSublayer(pivotMarker)

        let initialCamera = SCNCamera()
        let initialCameraNode = SCNNode()
        initialCameraNode.name = "Initial camera node"
        initialCameraNode.camera = initialCamera
        scene.rootNode.addChildNode(initialCameraNode)
        sceneView.pointOfView = initialCameraNode
        self.cameraNode = initialCameraNode

        sceneView.backgroundColor = backgroundColor
        sceneView.autoenablesDefaultLighting = false
        sceneView.allowsCameraControl = true
        sceneView.showsStatistics = false

        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 30
        let ambientLightNode = SCNNode()
        ambientLightNode.name = "Ambient light"
        ambientLightNode.light = ambientLight
        scene.rootNode.addChildNode(ambientLightNode)

        cameraLight.type = .directional
        cameraLight.intensity = 1000
        initialCameraNode.light = cameraLight

        sceneView.defaultCameraController.worldUp = SCNVector3(0, 0, 1)
        //sceneView.showsStatistics = true
        sceneView.delegate = self

        enum NodeCategory: Int {
            case `default` = 1
            case gridMask = 2
            case grid = 4
        }

        modelContainer.name = "Model container"
        gridContainer.name = "Grid container"
        coarseGrid.name = "Coarse grid"
        fineGrid.name = "Fine grid"
        gridCover.name = "Grid cover"
        gridCover.categoryBitMask = NodeCategory.gridMask.rawValue

        //gridCover.geometry?.firstMaterial?.blendMode = .alpha
        //gridCover.geometry?.firstMaterial?.isDoubleSided = true

        scene.rootNode.addChildNode(modelContainer)
        scene.rootNode.addChildNode(gridContainer)
        gridContainer.addChildNode(coarseGrid)
        gridContainer.addChildNode(fineGrid)

        coarseGrid.categoryBitMask = NodeCategory.grid.rawValue
        fineGrid.categoryBitMask = NodeCategory.grid.rawValue

        let extent = 10000.0
        let x = SCNNode(geometry: .lines([(SCNVector3(-extent, 0, 0), SCNVector3(extent, 0, 0))], color: .red))
        let y = SCNNode(geometry: .lines([(SCNVector3(0, -extent, 0), SCNVector3(0, extent, 0))], color: .green))
        let z = SCNNode(geometry: .lines([(SCNVector3(0, 0, -extent), SCNVector3(0, 0, extent))], color: .blue))
        gridContainer.addChildNode(x)
        gridContainer.addChildNode(y)
        gridContainer.addChildNode(z)

        updateCamera()

        objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            SCNTransaction.disableActions = true
            updateCamera()
            sceneViewBounds = sceneView.bounds
        }.store(in: &observers)

        modelStream.receive(on: DispatchQueue.main).sink { [weak self] modelData in
            guard let self else { return }
            print("Model updated!")
            let wasEmpty = modelContainer.childNodes.isEmpty
            modelContainer.childNodes.forEach { $0.removeFromParentNode() }
            modelContainer.addChildNode(modelData.rootNode)
            adjustDisplayMode()
            reloadNormalsState()
            if wasEmpty {
                self.showViewPreset(.isometric, animated: false)
            }
            self.parts = modelData.parts
        }.store(in: &observers)

        startNavLib()
    }

    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let gridScale = min(max(calculateGridScale(), 0.11), 99.99)
        updateGrid(scale: gridScale)

        if let currentCameraNode = sceneView.pointOfView, currentCameraNode != cameraNode {
            cameraNode.light = nil
            cameraNode = currentCameraNode
            currentCameraNode.light = cameraLight
            print("Camera node changed")
        }
    }

    func renderer(_ renderer: any SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        let localPoint = renderer.projectPoint(pivotPoint)
        let showPivot = showPivotMarker && (0..<1).contains(localPoint.z)

        let z = cameraNode.presentation.worldTransform.transformDirection(SIMD3<Float>(0, 0, -1)).z
        let hideGrid = z > 0 && cameraNode.camera!.usesOrthographicProjection
        coarseGrid.isHidden = hideGrid
        fineGrid.isHidden = hideGrid

        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            self.pivotMarker.opacity = showPivot ? 1 : 0
            CATransaction.commit()

            if !localPoint.x.isNaN {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.pivotMarker.position = CGPoint(x: localPoint.x, y: localPoint.y)
                CATransaction.commit()
            }
        }
    }

    func calculateGridScale() -> Double {
        let topLeft = CGPoint(x: sceneViewBounds.minX, y: sceneViewBounds.minY)
        let topRight = CGPoint(x: sceneViewBounds.maxX, y: sceneViewBounds.minY)
        let bottomLeft = CGPoint(x: sceneViewBounds.minX, y: sceneViewBounds.maxY)
        let bottomRight = CGPoint(x: sceneViewBounds.maxX, y: sceneViewBounds.maxY)

        let topLeftScale = sceneView.gridScale(at: topLeft)
        let topRightScale = sceneView.gridScale(at: topRight)
        let bottomLeftScale = sceneView.gridScale(at: bottomLeft)
        let bottomRightScale = sceneView.gridScale(at: bottomRight)

        return max(topLeftScale, topRightScale, bottomLeftScale, bottomRightScale)
    }

    func calculateOrthographicScale() -> Double {
        guard let cameraNode = sceneView.pointOfView,
              let camera = sceneView.pointOfView?.camera else { return 100.0 }

        let center = modelContainer.boundingSphere.center
        let distance = cameraNode.position.distance(from: center)
        let fovRadians = camera.fieldOfView * (.pi / 180.0)
        let scale = distance * tan(fovRadians / 2.0)

        return scale
    }

    func updateCamera() {
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
            camera.fieldOfView = 60
        }

        //session[.viewIsPerspective] = projection == .perspective

        sceneView.defaultCameraController.worldUp = SCNVector3(0, 0, 1)
        sceneView.defaultCameraController.automaticTarget = true
        sceneView.defaultCameraController.interactionMode = interactionMode

        updateNavLibProjection()
    }

    func updateGrid(scale: Double) {
        //print(scale)
        let lineDistance = 1 / pow(10, floor(log10(scale)) - 2)
        let fraction = 1 - (ceil(log10(scale)) - log10(scale))

        guard !lineDistance.isNaN else { return }

        let fullOpacity = 0.15
        let coarseCount = 100
        coarseGrid.geometry = makeGrid(lineDistance: lineDistance, count: coarseCount, color: .init(white: 1, alpha: fullOpacity))

        fineGrid.geometry = makeGrid(lineDistance: lineDistance / 10.0, count: coarseCount * 10, color: .init(white: 1, alpha: fraction * fullOpacity))

        coarseGrid.geometry?.firstMaterial?.blendMode = .alpha
        fineGrid.geometry?.firstMaterial?.blendMode = .alpha

        let size = Double(coarseCount) * lineDistance * 2
        (gridCover.geometry as? SCNPlane)?.width = size * 1.01
        (gridCover.geometry as? SCNPlane)?.height = size * 1.01
    }

    func makeGrid(lineDistance: Double, count: Int, color: NSColor) -> SCNGeometry {
        let range = -Double(count)*lineDistance...Double(count)*lineDistance
        let a = stride(from: range.lowerBound, through: range.upperBound, by: lineDistance).map { y in
            (SCNVector3(range.lowerBound, y, 0), SCNVector3(range.upperBound, y, 0))
        }
        let b = stride(from: range.lowerBound, through: range.upperBound, by: lineDistance).map { x in
            (SCNVector3(x, range.lowerBound, 0), SCNVector3(x, range.upperBound, 0))
        }

        return SCNGeometry.lines(a + b, color: color)
    }



    func showViewPreset(_ preset: ViewPreset, animated: Bool) {
        setCameraView(cameraView(for: preset), movement: animated ? .large : .instant)
    }

    func clearRoll() {
        setCameraView(clearRollView(), movement: .small)
    }

    func performMenuCommand(_ command: MenuCommand, tag: Int) {
        switch command {
        case .showViewPreset:
            guard let preset = ViewPreset(rawValue: tag) else {
                preconditionFailure("Invalid preset index")
            }
            showViewPreset(preset, animated: true)
        case .zoomIn:
            setCameraView(viewForZoom(amount: 3), movement: .small)
        case .zoomOut:
            setCameraView(viewForZoom(amount: -3), movement: .small)
        case .showRenderingOptions:
            let panelClass: AnyObject? = NSClassFromString("SCNRendererOptionsPanel")
            let panel = panelClass?.perform(NSSelectorFromString("rendererOptionsPanelForView:"), with: sceneView).takeUnretainedValue() as? NSPanel
            panel?.hidesOnDeactivate = true
            panel?.isFloatingPanel = true
            panel?.makeKeyAndOrderFront(nil)
        }
    }

    func canPerformMenuCommand(_ command: MenuCommand, tag: Int) -> Bool {
        return true
    }

    private func adjustDisplayMode() {
        SCNTransaction.disableActions = true
        modelContainer.enumerateChildNodes { node, _ in
            //node.geometry?.firstMaterial?.emission.contents = showAsWireframe ? NSColor.white : NSColor.black
            node.geometry?.firstMaterial?.isDoubleSided = showAsWireframe
        }
    }

    var showAsWireframe: Bool {
        get { sceneView.debugOptions.contains(.renderAsWireframe) }
        set {
            sceneView.debugOptions.subtract(.renderAsWireframe)
            sceneView.debugOptions.formUnion(newValue ? .renderAsWireframe : [])
            adjustDisplayMode()
        }
    }



    enum CameraProjection {
        case orthographic
        case perspective
    }

    enum ViewPreset: Int {
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
    }
}

extension SceneController {
    func reloadNormalsState() {
        modelContainer.enumerateChildNodes { node, _ in
            guard var geometry = node.geometry, let id = geometry.name else { return }

            if useNormals {
                if let cached = normalsCache[id] {
                    geometry = geometry.replacingNormals(cached)
                } else {
                    geometry = geometry.calculatingNormals()
                }
            } else {
                let (newGeometry, normals) = geometry.removingNormals()
                geometry = newGeometry
                if let normals {
                    normalsCache[id] = normals
                }
            }
            
            node.geometry = geometry
        }
    }
}

extension SCNMatrix4 {
    func transformDirection(_ direction: SIMD3<Float>) -> SIMD3<Float> {
        let matrix = float4x4(self)
        let transformed = simd_mul(matrix, SIMD4<Float>(direction.x, direction.y, direction.z, 0))
        return SIMD3<Float>(transformed.x, transformed.y, transformed.z)
    }
}

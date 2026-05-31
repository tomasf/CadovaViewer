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

    /// World-space corner vertices (endpoints of the model's sharp/feature edges) that
    /// the measurement tool can snap to when Option is held. Rebuilt on model load.
    private var snapVertices: [SCNVector3] = []

    /// Screen-space bucket of `snapVertices` so hover lookups don't re-project every corner.
    /// Rebuilt only when the camera/viewport changes.
    private var snapGridCells: [SIMD2<Int>: [(vertex: SCNVector3, screen: CGPoint)]] = [:]
    private let snapGridCellSize = 16.0
    private var snapGridWorldTransform = SCNMatrix4Identity
    private var snapGridProjection = SCNMatrix4Identity
    private var snapGridViewSize = CGSize.zero

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
            snapVertices = gatherSnapVertices()
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
        let modifiers = NSEvent.modifierFlags
        if modifiers.contains(.option), let vertex = nearestSnapVertex(toViewPoint: point, flipY: flipY) {
            return vertex
        }
        if modifiers.contains(.shift), let start = measurementController.inProgressStart {
            return axisConstrainedPoint(atViewPoint: point, flipY: flipY, from: start)
        }
        return surfaceWorldPoint(atViewPoint: point, flipY: flipY)
    }

    /// Nearest *visible* corner vertex (sharp-edge endpoint) whose screen projection is
    /// within a small radius of the cursor, or nil if none qualifies. Corners hidden
    /// behind the model are skipped.
    private func nearestSnapVertex(toViewPoint point: CGPoint, flipY: Bool) -> SCNVector3? {
        guard !snapVertices.isEmpty else { return nil }
        let viewPoint = flipY ? CGPoint(x: point.x, y: sceneViewSize.height - point.y) : point
        ensureSnapGrid()

        let threshold = 14.0 // view points
        let cellX = Int((Double(viewPoint.x) / snapGridCellSize).rounded(.down))
        let cellY = Int((Double(viewPoint.y) / snapGridCellSize).rounded(.down))

        var nearby: [(vertex: SCNVector3, distance: Double)] = []
        for dx in -1...1 {
            for dy in -1...1 {
                for entry in snapGridCells[SIMD2(cellX + dx, cellY + dy)] ?? [] {
                    let distance = hypot(Double(entry.screen.x - viewPoint.x), Double(entry.screen.y - viewPoint.y))
                    if distance < threshold {
                        nearby.append((entry.vertex, distance))
                    }
                }
            }
        }

        return nearby.sorted { $0.distance < $1.distance }
            .first { isVertexVisible($0.vertex) }?
            .vertex
    }

    /// Rebuilds the screen-space bucket if the camera or viewport has changed since it was
    /// last built; otherwise reuses it (the common case while hovering with a still camera).
    private func ensureSnapGrid() {
        guard let pointOfView = sceneView.pointOfView else { return }
        let worldTransform = pointOfView.worldTransform
        let projection = pointOfView.camera?.projectionTransform ?? SCNMatrix4Identity

        if snapGridViewSize == sceneViewSize,
           SCNMatrix4EqualToMatrix4(worldTransform, snapGridWorldTransform),
           SCNMatrix4EqualToMatrix4(projection, snapGridProjection) {
            return
        }
        snapGridWorldTransform = worldTransform
        snapGridProjection = projection
        snapGridViewSize = sceneViewSize

        snapGridCells.removeAll(keepingCapacity: true)
        for vertex in snapVertices {
            let projected = sceneView.projectPoint(vertex)
            guard projected.z >= 0, projected.z <= 1 else { continue }
            let key = SIMD2(Int((Double(projected.x) / snapGridCellSize).rounded(.down)),
                            Int((Double(projected.y) / snapGridCellSize).rounded(.down)))
            snapGridCells[key, default: []].append((vertex, CGPoint(x: projected.x, y: projected.y)))
        }
    }

    /// Whether a corner vertex is unobstructed from the camera: casts at the vertex's
    /// screen position and checks nothing on the model is meaningfully nearer than it.
    private func isVertexVisible(_ vertex: SCNVector3) -> Bool {
        guard let cameraNode = sceneView.pointOfView else { return true }
        let cameraPosition = cameraNode.presentation.worldPosition
        let vertexDistance = vertex.distance(from: cameraPosition)

        // Only the closest hit is needed (SceneKit's default search mode), which is far
        // cheaper than searching all intersections. Edge nodes sit on the surface (nudged
        // toward the camera by ~0.1%), so they stay within the tolerance below.
        let screenPoint = sceneView.projectPoint(vertex)
        let nearestHit = sceneView.hitTest(CGPoint(x: screenPoint.x, y: screenPoint.y), options: [
            .rootNode: sceneController.modelContainer
        ]).first

        // No surface in front of the point (e.g. a silhouette corner) → treat as visible.
        guard let nearestHit else { return true }
        let hitDistance = nearestHit.worldCoordinates.distance(from: cameraPosition)
        return hitDistance >= vertexDistance * 0.98
    }

    /// Collects the world-space endpoints of every part's sharp (feature) edges, which are
    /// the genuine corner vertices — flat-surface and smooth-tessellation vertices are
    /// excluded because they don't lie on a sharp edge.
    private func gatherSnapVertices() -> [SCNVector3] {
        var seen = Set<SIMD3<Int>>()
        var result: [SCNVector3] = []

        for part in sceneController.parts {
            guard let sharpEdges = part.nodes.sharpEdges else { continue }
            sharpEdges.enumerateHierarchy { node, _ in
                guard let geometry = node.geometry,
                      let source = geometry.sources(for: .vertex).first,
                      let element = geometry.elements.first else { return }

                let vertices = decodeVertices(source)
                for index in Set(decodeLineIndices(element)) where index < vertices.count {
                    let world = node.convertPosition(vertices[index], to: nil)
                    let key = SIMD3<Int>(Int((world.x * 1000).rounded()), Int((world.y * 1000).rounded()), Int((world.z * 1000).rounded()))
                    if seen.insert(key).inserted {
                        result.append(world)
                    }
                }
            }
        }
        return result
    }

    private func decodeVertices(_ source: SCNGeometrySource) -> [SCNVector3] {
        let count = source.vectorCount
        let stride = source.dataStride
        let offset = source.dataOffset
        let wide = source.bytesPerComponent == 8
        return source.data.withUnsafeBytes { raw -> [SCNVector3] in
            var vertices: [SCNVector3] = []
            vertices.reserveCapacity(count)
            for i in 0..<count {
                let base = i * stride + offset
                if wide {
                    let x = raw.loadUnaligned(fromByteOffset: base, as: Float64.self)
                    let y = raw.loadUnaligned(fromByteOffset: base + 8, as: Float64.self)
                    let z = raw.loadUnaligned(fromByteOffset: base + 16, as: Float64.self)
                    vertices.append(SCNVector3(x, y, z))
                } else {
                    let x = raw.loadUnaligned(fromByteOffset: base, as: Float32.self)
                    let y = raw.loadUnaligned(fromByteOffset: base + 4, as: Float32.self)
                    let z = raw.loadUnaligned(fromByteOffset: base + 8, as: Float32.self)
                    vertices.append(SCNVector3(CGFloat(x), CGFloat(y), CGFloat(z)))
                }
            }
            return vertices
        }
    }

    private func decodeLineIndices(_ element: SCNGeometryElement) -> [Int] {
        guard element.primitiveType == .line else { return [] }
        let indexCount = element.primitiveCount * 2
        let bytesPerIndex = element.bytesPerIndex
        return element.data.withUnsafeBytes { raw -> [Int] in
            var indices: [Int] = []
            indices.reserveCapacity(indexCount)
            for i in 0..<indexCount {
                let base = i * bytesPerIndex
                switch bytesPerIndex {
                case 1: indices.append(Int(raw.loadUnaligned(fromByteOffset: base, as: UInt8.self)))
                case 2: indices.append(Int(raw.loadUnaligned(fromByteOffset: base, as: UInt16.self)))
                case 8: indices.append(Int(raw.loadUnaligned(fromByteOffset: base, as: UInt64.self)))
                default: indices.append(Int(raw.loadUnaligned(fromByteOffset: base, as: UInt32.self)))
                }
            }
            return indices
        }
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

import Cocoa
import QuickLookUI
import SceneKit
import ThreeMF
import SwiftUI
import Combine
import ViewerCore

class PreviewViewController: NSViewController, QLPreviewingController, SCNSceneRendererDelegate {
    private var sceneView: SCNView?
    private var grid: ViewportGrid?
    private var modelNode: SCNNode?
    private var parts: [ModelData.Part] = []
    private var toolbar: NSVisualEffectView?
    
    private var edgeNodes: Set<SCNNode> = []
    private var cameraLightNode: SCNNode?
    private var sceneViewSize: CGSize = .zero
    private let orientationSubject = CurrentValueSubject<OrientationIndicatorValues, Never>(.init(x: .zero, y: .zero, z: .zero))
    private var edgeVisibility: EdgeVisibility = .sharp {
        didSet { updateEdgeVisibility() }
    }

    override func loadView() {
        view = NSView()
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let modelData = try await ModelData(url: url, includeEdges: true)

        await MainActor.run {
            let scene = SCNScene()
            scene.lightingEnvironment.contents = SceneLighting.environmentImage
            scene.rootNode.addChildNode(modelData.rootNode)
            self.modelNode = modelData.rootNode
            self.parts = modelData.parts
            self.edgeNodes = Set(modelData.parts.flatMap { [$0.nodes.sharpEdges, $0.nodes.smoothEdges].compactMap { $0 } })

            let ambientLight = SCNLight()
            ambientLight.type = .ambient
            ambientLight.intensity = 30
            let ambientLightNode = SCNNode()
            ambientLightNode.light = ambientLight
            scene.rootNode.addChildNode(ambientLightNode)

            let grid = ViewportGrid()
            grid.updateBounds(geometry: modelData.rootNode)
            grid.showOrigin = false
            scene.rootNode.addChildNode(grid.node)
            self.grid = grid

            let sceneView = PreviewSceneView(frame: view.bounds)
            sceneView.modelNode = modelData.rootNode
            sceneView.autoresizingMask = [.width, .height]
            sceneView.scene = scene
            sceneView.allowsCameraControl = true
            sceneView.autoenablesDefaultLighting = false
            sceneView.backgroundColor = NSColor(white: 0.05, alpha: 1)
            sceneView.delegate = self

            setupCamera(for: modelData.rootNode, in: scene, sceneView: sceneView)

            let worldCenter = modelData.rootNode.convertPosition(modelData.rootNode.boundingSphere.center, to: nil)
            sceneView.defaultCameraController.target = worldCenter

            sceneView.defaultCameraController.worldUp = SCNVector3(0, 0, 1)
            sceneView.defaultCameraController.automaticTarget = true
            sceneView.defaultCameraController.interactionMode = .orbitTurntable

            view.addSubview(sceneView)
            self.sceneView = sceneView
            
            setupToolbar()
            setupCoordinateIndicator()
            updateEdgeVisibility()
        }
    }

    private func setupCamera(for modelNode: SCNNode, in scene: SCNScene, sceneView: SCNView) {
        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        camera.fieldOfView = 30

        let cameraLight = SCNLight()
        cameraLight.type = .directional
        cameraLight.intensity = 800
        let lightNode = SCNNode()
        lightNode.light = cameraLight
        scene.rootNode.addChildNode(lightNode)
        cameraLightNode = lightNode

        let cameraNode = SCNNode()
        cameraNode.camera = camera

        scene.rootNode.addChildNode(cameraNode)
        sceneView.pointOfView = cameraNode

        cameraNode.simdTransform = cameraTransform(for: .isometric)
    }

    // MARK: - View Presets

    func showViewPreset(_ preset: ViewPreset) {
        guard let cameraNode = sceneView?.pointOfView else { return }
        
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.3
        cameraNode.simdTransform = cameraTransform(for: preset)
        SCNTransaction.commit()
    }
    
    private func cameraTransform(for preset: ViewPreset) -> float4x4 {
        guard let modelNode = modelNode else { return matrix_identity_float4x4 }

        let (minBound, maxBound) = modelNode.boundingBox
        let boundingBox = (
            min: SIMD3<Double>(Double(minBound.x), Double(minBound.y), Double(minBound.z)),
            max: SIMD3<Double>(Double(maxBound.x), Double(maxBound.y), Double(maxBound.z))
        )
        let center = (boundingBox.min + boundingBox.max) / 2

        let bounds = view.bounds.size
        let aspectRatio = bounds.width > 0 && bounds.height > 0 ? Double(bounds.width / bounds.height) : 1

        let axis = preset.axis
        let framing = frameBoundingBox(
            axis: axis,
            boundingBox: boundingBox,
            center: center,
            fieldOfViewDegrees: 30,
            aspectRatio: aspectRatio
        )
        let position = center + axis * framing.distance

        return float4x4(lookingFrom: SIMD3<Float>(position), at: SIMD3<Float>(center))
    }

    // MARK: - Edge Visibility
    
    enum EdgeVisibility: Int {
        case none = 0
        case sharp = 1
        case all = 2
    }
    
    private func updateEdgeVisibility() {
        for part in parts {
            part.nodes.sharpEdges?.isHidden = (edgeVisibility == .none)
            part.nodes.smoothEdges?.isHidden = (edgeVisibility != .all)
        }
    }
    
    // MARK: - Toolbar
    
    private func setupToolbar() {
        let toolbarHeight: CGFloat = 32
        let toolbarWidth: CGFloat = 100
        
        let toolbar = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: toolbarWidth, height: toolbarHeight))
        toolbar.material = .hudWindow
        toolbar.blendingMode = .withinWindow
        toolbar.state = .active
        toolbar.wantsLayer = true
        toolbar.layer?.cornerRadius = 8
        
        let stackView = NSStackView()
        stackView.orientation = .horizontal
        stackView.spacing = 2
        stackView.alignment = .centerY
        stackView.translatesAutoresizingMaskIntoConstraints = false
        
        // Isometric button
        let isoButton = makeViewButton(
            symbolName: "cube",
            tag: ViewPreset.isometric.rawValue,
            toolTip: "Isometric"
        )
        stackView.addArrangedSubview(isoButton)
        
        // Front button
        let frontButton = makeViewButton(
            symbolName: "square",
            tag: ViewPreset.front.rawValue,
            toolTip: "Front"
        )
        stackView.addArrangedSubview(frontButton)
        
        // Top button
        let topButton = makeViewButton(
            symbolName: "square.topthird.inset.filled",
            tag: ViewPreset.top.rawValue,
            toolTip: "Top"
        )
        stackView.addArrangedSubview(topButton)
        
        toolbar.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: toolbar.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor)
        ])
        
        // Position toolbar at bottom right
        toolbar.frame = NSRect(
            x: view.bounds.width - toolbarWidth - 16,
            y: 16,
            width: toolbarWidth,
            height: toolbarHeight
        )
        toolbar.autoresizingMask = [.minXMargin, .maxYMargin]
        
        view.addSubview(toolbar)
        self.toolbar = toolbar
    }
    
    private func makeViewButton(symbolName: String, tag: Int, toolTip: String) -> NSButton {
        let button = NSButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        button.bezelStyle = .toolbar
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: toolTip)
        button.imagePosition = .imageOnly
        button.tag = tag
        button.target = self
        button.action = #selector(viewPresetButtonClicked(_:))
        button.toolTip = toolTip
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        button.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return button
    }
    
    @objc private func viewPresetButtonClicked(_ sender: NSButton) {
        guard let preset = ViewPreset(rawValue: sender.tag) else { return }
        showViewPreset(preset)
    }

    private func setupCoordinateIndicator() {
        let indicatorView = CoordinateSystemIndicator(stream: orientationSubject.eraseToAnyPublisher())
        let hostingView = NSHostingView(rootView: indicatorView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            hostingView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8),
        ])
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        sceneViewSize = sceneView?.bounds.size ?? .zero
    }

    // MARK: - SCNSceneRendererDelegate

    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let sceneView = sceneView else { return }
        grid?.updateScale(renderer: sceneView, viewSize: sceneViewSize)
    }

    func renderer(_ renderer: any SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        guard let sceneView, let cameraNode = sceneView.pointOfView else { return }
        grid?.updateVisibility(cameraNode: cameraNode)

        let pov = cameraNode.presentation
        cameraLightNode?.simdWorldTransform = pov.simdWorldTransform
        orientationSubject.send(OrientationIndicatorValues(
            x: pov.convertVector(SCNVector3(1, 0, 0), from: nil),
            y: pov.convertVector(SCNVector3(0, 1, 0), from: nil),
            z: pov.convertVector(SCNVector3(0, 0, 1), from: nil)
        ))

        sceneView.applyEdgeDepthOffset(
            edgeNodes: Array(edgeNodes),
            cameraNode: cameraNode,
            modelNode: modelNode!,
            viewSize: sceneViewSize
        )
        // Edge lines are left at Metal's default 1-pixel line width.
    }
}

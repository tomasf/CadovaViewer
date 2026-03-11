import Cocoa
import QuickLookUI
import SceneKit
import ThreeMF

class PreviewViewController: NSViewController, QLPreviewingController, SCNSceneRendererDelegate {
    private var sceneView: SCNView?
    private var grid: ViewportGrid?
    private var modelNode: SCNNode?
    private var parts: [ModelData.Part] = []
    private var toolbar: NSVisualEffectView?
    
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
            scene.rootNode.addChildNode(modelData.rootNode)
            self.modelNode = modelData.rootNode
            self.parts = modelData.parts

            setupLighting(in: scene)

            let grid = ViewportGrid(categoryID: 0)
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
            
            sceneView.defaultCameraController.worldUp = SCNVector3(0, 0, 1)
            sceneView.defaultCameraController.automaticTarget = true
            sceneView.defaultCameraController.interactionMode = .orbitTurntable
            
            let worldCenter = modelData.rootNode.convertPosition(modelData.rootNode.boundingSphere.center, to: nil)
            sceneView.defaultCameraController.target = worldCenter

            view.addSubview(sceneView)
            self.sceneView = sceneView
            
            setupToolbar()
            updateEdgeVisibility()
        }
    }

    private func setupLighting(in scene: SCNScene) {
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 30
        let ambientLightNode = SCNNode()
        ambientLightNode.light = ambientLight
        scene.rootNode.addChildNode(ambientLightNode)

        let directionalLight = SCNLight()
        directionalLight.type = .directional
        directionalLight.intensity = 500
        directionalLight.color = NSColor.white
        directionalLight.castsShadow = false
        let directionalLightNode = SCNNode()
        directionalLightNode.light = directionalLight
        directionalLightNode.eulerAngles = SCNVector3(-Float.pi / 4, Float.pi / 4, 0)
        scene.rootNode.addChildNode(directionalLightNode)

        let fillLight = SCNLight()
        fillLight.type = .directional
        fillLight.intensity = 200
        fillLight.color = NSColor.white
        let fillLightNode = SCNNode()
        fillLightNode.light = fillLight
        fillLightNode.eulerAngles = SCNVector3(Float.pi / 6, -Float.pi / 3, 0)
        scene.rootNode.addChildNode(fillLightNode)
    }

    private func setupCamera(for modelNode: SCNNode, in scene: SCNScene, sceneView: SCNView) {
        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        camera.fieldOfView = 30

        let cameraNode = SCNNode()
        cameraNode.camera = camera
        
        scene.rootNode.addChildNode(cameraNode)
        sceneView.pointOfView = cameraNode
        
        cameraNode.simdTransform = cameraTransform(for: .isometric)
    }

    // MARK: - View Presets
    
    enum ViewPreset: Int, CaseIterable {
        case isometric
        case front
        case back
        case left
        case right
        case top
        case bottom
        
        var title: String {
            switch self {
            case .isometric: return "Iso"
            case .front: return "Front"
            case .back: return "Back"
            case .left: return "Left"
            case .right: return "Right"
            case .top: return "Top"
            case .bottom: return "Bottom"
            }
        }
    }
    
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
        let center = simd_float3(
            Float((minBound.x + maxBound.x) / 2),
            Float((minBound.y + maxBound.y) / 2),
            Float((minBound.z + maxBound.z) / 2)
        )
        
        let sizeX = Float(maxBound.x - minBound.x)
        let sizeY = Float(maxBound.y - minBound.y)
        let sizeZ = Float(maxBound.z - minBound.z)
        
        let fovRadians: Float = 30 * (.pi / 180.0)
        let objectSizeX = max(sizeY, sizeZ)
        let objectSizeY = max(sizeX, sizeZ)
        let objectSizeZ = max(sizeX, sizeY)
        let distanceX = (objectSizeX / 2) / tan(fovRadians / 2)
        let distanceY = (objectSizeY / 2) / tan(fovRadians / 2)
        let distanceZ = (objectSizeZ / 2) / tan(fovRadians / 2)
        
        var position = center
        
        switch preset {
        case .isometric:
            let isoAngle: Float = 35.264 * (.pi / 180)
            let isoDist = max(distanceX, distanceY, distanceZ)
            position = simd_float3(
                center.x - isoDist * cos(isoAngle),
                center.y - isoDist * cos(isoAngle),
                center.z + isoDist * sin(isoAngle)
            )
        case .front:
            position.y = Float(minBound.y) - distanceY
        case .back:
            position.y = Float(maxBound.y) + distanceY
        case .left:
            position.x = Float(minBound.x) - distanceX
        case .right:
            position.x = Float(maxBound.x) + distanceX
        case .top:
            position.z = Float(maxBound.z) + distanceZ
        case .bottom:
            position.z = Float(minBound.z) - distanceZ
            position.x += 0.001
        }
        
        return makeCameraTransform(position: position, target: center)
    }

    private func makeCameraTransform(position: simd_float3, target: simd_float3) -> float4x4 {
        let worldUp = simd_float3(0, 0, 1)
        var forward = target - position
        if simd_length_squared(forward) < 1.0e-12 {
            return matrix_identity_float4x4
        }
        forward = simd_normalize(forward)

        var right = simd_cross(forward, worldUp)
        if simd_length_squared(right) < 1.0e-6 {
            right = simd_dot(forward, worldUp) > 0
                ? simd_float3(-1, 0, 0)
                : simd_float3(1, 0, 0)
        }
        right = simd_normalize(right)

        return float4x4(columns: (
            simd_float4(right, 0),
            simd_float4(simd_normalize(simd_cross(right, forward)), 0),
            simd_float4(-forward, 0),
            simd_float4(position, 1)
        ))
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

    // MARK: - SCNSceneRendererDelegate

    func renderer(_ renderer: any SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let sceneView = sceneView else { return }
        grid?.updateScale(renderer: sceneView, viewSize: sceneView.bounds.size)
    }

    func renderer(_ renderer: any SCNSceneRenderer, willRenderScene scene: SCNScene, atTime time: TimeInterval) {
        guard let cameraNode = sceneView?.pointOfView else { return }
        grid?.updateVisibility(cameraNode: cameraNode)
    }
}

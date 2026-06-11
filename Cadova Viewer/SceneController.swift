import Foundation
import SceneKit
import Combine
import ThreeMF
import ViewerCore

final class SceneController: ObservableObject {
    let scene = SCNScene()
    let modelContainer = SCNNode()
    let viewportPrivateContainer = SCNNode()

    @Published var parts: [ModelData.Part] = []

    /// Document-wide view options that act on the shared geometry (smooth shading, edge
    /// visibility). Owned here, not on any single viewport, because they mutate the shared parts.
    @Published var documentOptions: DocumentViewOptions = Preferences().documentViewOptions {
        didSet {
            applyDocumentOptions()
            Preferences().documentViewOptions = documentOptions
        }
    }

    /// The model's bounding box and sphere, cached when the model loads. Computing these from
    /// `modelContainer` walks the whole node hierarchy and takes SceneKit's scene lock, which
    /// contends with the render thread — costly when read on every NavLib (SpaceMouse) motion
    /// frame on the main thread. The model is static after load, so cache them once.
    private(set) var modelBoundingBox: (min: SCNVector3, max: SCNVector3) = (SCNVector3Zero, SCNVector3Zero)
    private(set) var modelBoundingSphere: (center: SCNVector3, radius: Float) = (SCNVector3Zero, 0)

    private let modelLoadedSignal = PassthroughSubject<Void, Never>()
    var modelWasLoaded: AnyPublisher<Void, Never> { modelLoadedSignal.eraseToAnyPublisher() }

    private var observers: Set<AnyCancellable> = []

    init(document: Document) {
        let names = ["right", "left", "front", "back", "bottom", "top"]
        let images = names.map { NSImage(named: "skybox4/\($0)")! }
        scene.lightingEnvironment.contents = images

        modelContainer.name = "Model container"
        scene.rootNode.addChildNode(modelContainer)

        viewportPrivateContainer.name = "Viewport-private container"
        scene.rootNode.addChildNode(viewportPrivateContainer)

        setupAmbientLight()

        DispatchQueue.main.async { [weak self, modelStream = document.modelStream] in
            self?.subscribe(to: modelStream)
        }
    }

    private func subscribe(to modelStream: AnyPublisher<ModelData, Never>) {
        modelStream.receive(on: DispatchQueue.main).sink { [weak self] modelData in
            self?.load(modelData)
        }.store(in: &observers)
    }

    private func load(_ modelData: ModelData) {
        modelContainer.childNodes.forEach { $0.removeFromParentNode() }
        modelContainer.addChildNode(modelData.rootNode)

        let previousVisibility = Dictionary(parts.map {
            ($0.id, $0.nodes.container.categoryBitMask)
        }, uniquingKeysWith: { $1 })

        parts = modelData.parts

        // Should the viewport controllers do this instead? They know their hidden IDs
        for part in parts {
            if let previousCategoryBitMask = previousVisibility[part.id] {
                part.nodes.container.setSubtreeCategoryBitMask(previousCategoryBitMask)
            } else {
                part.nodes.container.setSubtreeCategoryBitMask(~1)
            }
        }

        modelBoundingBox = modelContainer.boundingBox
        modelBoundingSphere = modelContainer.boundingSphere

        applyDocumentOptions()
        modelLoadedSignal.send()
    }

    // MARK: - Document-wide geometry options

    func applyDocumentOptions() {
        setEdgeVisibility(documentOptions.edgeVisibility)
        setSmoothShading(documentOptions.smoothShading)
    }

    func setEdgeVisibility(_ visibility: DocumentViewOptions.EdgeVisibility) {
        for part in parts {
            part.nodes.sharpEdges?.isHidden = (visibility == .none)
            part.nodes.smoothEdges?.isHidden = (visibility != .all)
        }
    }

    /// Swaps every main-geometry node between its faceted (flat) geometry and a smooth-shaded
    /// variant. Turning smooth shading off is an instant main-thread swap. Turning it on builds
    /// the smooth geometry off the main thread on first use (cached thereafter), then applies the
    /// swap on the main actor, so large models don't hitch the UI.
    func setSmoothShading(_ smooth: Bool) {
        let variants = parts.flatMap(\.modelGeometryVariants)
        guard smooth else {
            for variant in variants {
                variant.node.geometry = variant.flat
            }
            return
        }

        Task.detached {
            await withTaskGroup(of: (ModelGeometryVariant, SCNGeometry).self) { group in
                for variant in variants {
                    group.addTask { (variant, variant.smoothGeometry()) }
                }
                for await (variant, geometry) in group {
                    await MainActor.run { variant.node.geometry = geometry }
                }
            }
        }
    }

    private func setupAmbientLight() {
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 30
        let ambientLightNode = SCNNode()
        ambientLightNode.name = "Ambient light"
        ambientLightNode.light = ambientLight
        scene.rootNode.addChildNode(ambientLightNode)
    }

    func viewportPrivateNode(for id: Int) -> SCNNode {
        if let node = viewportPrivateContainer.childNodes.first(where: { ($0.categoryBitMask & (1 << id)) > 0 }) {
            return node
        }

        // The category bitmask is only used for keeping track of the IDs. It doesn't actually affect child nodes inside the container (sadly).
        let node = SCNNode()
        node.categoryBitMask = (1 << id)
        node.name = "Viewport-private node \(id)"
        viewportPrivateContainer.addChildNode(node)
        return node
    }

    /// Removes a viewport's private node (its grid, measurement geometry, etc.) when the viewport
    /// is closed.
    func removeViewportPrivateNode(for id: Int) {
        viewportPrivateContainer.childNodes
            .first { ($0.categoryBitMask & (1 << id)) > 0 }?
            .removeFromParentNode()
    }

    var edgeNodes: [SCNNode] {
        let edgeContainers = parts.compactMap(\.nodes.sharpEdges) + parts.compactMap(\.nodes.smoothEdges)
        return edgeContainers.flatMap { $0.childNodes { node, _ in node.geometry != nil }}
    }
}

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

        modelLoadedSignal.send()
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

    var edgeNodes: [SCNNode] {
        let edgeContainers = parts.compactMap(\.nodes.sharpEdges) + parts.compactMap(\.nodes.smoothEdges)
        return edgeContainers.flatMap { $0.childNodes { node, _ in node.geometry != nil }}
    }
}

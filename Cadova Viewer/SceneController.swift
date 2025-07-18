import Foundation
import SceneKit
import Combine

final class SceneController: ObservableObject {
    let scene = SCNScene()
    let modelContainer = SCNNode()
    let viewportPrivateContainer = SCNNode()

    @Published var parts: [ModelData.Part] = []

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

        document.modelStream.receive(on: DispatchQueue.main).sink { [weak self] modelData in
            guard let self else { return }

            modelContainer.childNodes.forEach { $0.removeFromParentNode() }
            modelContainer.addChildNode(modelData.rootNode)

            let previousVisibility = Dictionary(parts.map {
                ($0.id, $0.nodes.model.categoryBitMask)
            }, uniquingKeysWith: { $1 })

            parts = modelData.parts

            // Should the viewport controllers do this instead? They know their hidden IDs
            for part in parts {
                if let previousCategoryBitMask = previousVisibility[part.id] {
                    part.nodes.model.treeCategoryBitMask = previousCategoryBitMask
                } else {
                    part.nodes.model.treeCategoryBitMask = ~1
                }
            }

            modelLoadedSignal.send()
        }.store(in: &observers)

        setupAmbientLight()
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
        if let node = viewportPrivateContainer.childNodes.first(where: { $0.categoryBitMask | (1 << id) > 0 }) {
            return node
        }

        // The category bitmask is only used for keeping track of the IDs. It doesn't actually affect child nodes inside the container (sadly).
        let node = SCNNode()
        node.categoryBitMask = (1 << id)
        node.name = "Viewport-private node \(id)"
        viewportPrivateContainer.addChildNode(node)
        return node
    }
}

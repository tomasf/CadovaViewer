import Foundation
import SceneKit
import Combine
import ThreeMF
import ViewerCore

/// Owns the shared, document-wide model data. It does not own a rendered scene: each viewport
/// renders its own `SCNScene` built from `modelData` (see `ViewportModelInstance`), sharing the
/// heavy `SCNGeometry` while keeping its own lights and per-viewport visibility. This object holds
/// what is genuinely shared — the loaded model, the parts list, the document-global geometry
/// options (edge visibility, smooth shading), the cached bounds, and the skybox.
final class SceneController: ObservableObject {
    /// Image-based-lighting faces, shared as each viewport scene's `lightingEnvironment`.
    let skyboxImages: [NSImage]

    /// The master model hierarchy. Not added to any rendered scene — it's the source each viewport
    /// clones from.
    private(set) var modelData = ModelData()

    @Published var parts: [ModelData.Part] = []

    /// Document-global, lazily-rendered part thumbnails for the sidebar. Shared across
    /// viewports (the geometry is the same in each), so it lives here.
    let thumbnails = PartThumbnailService()

    /// Document-wide view options that act on the shared geometry (smooth shading, edge
    /// visibility). Owned here, not on any single viewport, because they apply to every viewport
    /// identically. Viewports observe `documentGeometryChanged` and apply them to their own clones.
    @Published var documentOptions: DocumentViewOptions = Preferences().documentViewOptions {
        didSet {
            if documentOptions.smoothShading, !oldValue.smoothShading {
                buildSmoothGeometries()
            }
            geometryChanged.send()
            Preferences().documentViewOptions = documentOptions
        }
    }

    /// The model's bounding box and sphere, cached when the model loads. Computing these walks the
    /// whole node hierarchy and takes SceneKit's scene lock, which contends with the render thread
    /// — costly when read on every NavLib (SpaceMouse) motion frame on the main thread. The model
    /// is static after load, so cache them once.
    private(set) var modelBoundingBox: (min: SCNVector3, max: SCNVector3) = (SCNVector3Zero, SCNVector3Zero)
    private(set) var modelBoundingSphere: (center: SCNVector3, radius: Float) = (SCNVector3Zero, 0)

    private let modelLoadedSignal = PassthroughSubject<Void, Never>()
    var modelWasLoaded: AnyPublisher<Void, Never> { modelLoadedSignal.eraseToAnyPublisher() }

    /// Fires when a document-global geometry option changes (or a background smooth-geometry build
    /// finishes). Each viewport re-applies the options to its own clone nodes.
    private let geometryChanged = PassthroughSubject<Void, Never>()
    var documentGeometryChanged: AnyPublisher<Void, Never> { geometryChanged.eraseToAnyPublisher() }

    private var observers: Set<AnyCancellable> = []

    init(document: Document) {
        let names = ["right", "left", "front", "back", "bottom", "top"]
        skyboxImages = names.map { NSImage(named: "skybox4/\($0)")! }

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
        self.modelData = modelData
        parts = modelData.parts
        thumbnails.setParts(modelData.parts)

        modelBoundingBox = modelData.rootNode.boundingBox
        modelBoundingSphere = modelData.rootNode.boundingSphere

        if documentOptions.smoothShading {
            buildSmoothGeometries()
        }
        modelLoadedSignal.send()
    }

    // MARK: - Document-wide geometry options

    /// Builds the smooth-shaded geometry for every part off the main thread (the result is cached
    /// on each shared `ModelGeometryVariant`), then notifies the viewports to swap it in. Keeps
    /// large models from hitching the UI, and builds each variant once for all viewports.
    private func buildSmoothGeometries() {
        let variants = parts.flatMap(\.modelGeometryVariants)
        guard !variants.isEmpty else { return }
        Task.detached { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for variant in variants {
                    group.addTask { _ = variant.smoothGeometry() }
                }
            }
            await MainActor.run { self?.geometryChanged.send() }
        }
    }
}

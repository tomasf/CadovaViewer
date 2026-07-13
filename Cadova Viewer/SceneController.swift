import Foundation
import SceneKit
import Combine
import ThreeMF
import ViewerCore

/// Owns the shared, document-wide model data. It does not own a rendered scene: each viewport
/// renders its own `SCNScene` built from `modelData` (see `ViewportModelInstance`), sharing the
/// heavy `SCNGeometry` while keeping its own lights and per-viewport visibility. This object holds
/// what is genuinely shared — the loaded model, the parts list, the shared smooth-geometry build,
/// the cached bounds, and the lighting environment. Smooth shading and edge visibility are
/// per-viewport (`ViewOptions`); only the expensive smooth-normal computation itself is shared.
final class SceneController: ObservableObject {
    /// Image-based-lighting environment, shared as each viewport scene's `lightingEnvironment`.
    /// A procedural neutral gray gradient (bright overhead, dark underfoot) rather than a
    /// photographic skybox, so reflections read as soft studio lighting instead of recognizable
    /// scenery, and part shading stays consistent regardless of orientation.
    let environmentImage: NSImage = SceneController.makeEnvironmentImage()

    /// The master model hierarchy. Not added to any rendered scene — it's the source each viewport
    /// clones from.
    private(set) var modelData = ModelData()

    @Published var parts: [ModelData.Part] = []

    /// Document-global, lazily-rendered part thumbnails for the sidebar. Shared across
    /// viewports (the geometry is the same in each), so it lives here.
    let thumbnails = PartThumbnailService()

    /// The model's bounding box and sphere, cached when the model loads. Computing these walks the
    /// whole node hierarchy and takes SceneKit's scene lock, which contends with the render thread
    /// — costly when read on every NavLib (SpaceMouse) motion frame on the main thread. The model
    /// is static after load, so cache them once.
    private(set) var modelBoundingBox: (min: SCNVector3, max: SCNVector3) = (SCNVector3Zero, SCNVector3Zero)
    private(set) var modelBoundingSphere: (center: SCNVector3, radius: Float) = (SCNVector3Zero, 0)

    private let modelLoadedSignal = PassthroughSubject<Void, Never>()
    var modelWasLoaded: AnyPublisher<Void, Never> { modelLoadedSignal.eraseToAnyPublisher() }

    /// Fires when the shared smooth-shaded geometry finishes building in the background. Each
    /// viewport that wants smooth shading re-applies it to its own clone nodes (falling back to flat
    /// until this fires, in case it asked before the build was ready).
    private let smoothGeometryDidBuildSignal = PassthroughSubject<Void, Never>()
    var smoothGeometryDidBuild: AnyPublisher<Void, Never> { smoothGeometryDidBuildSignal.eraseToAnyPublisher() }

    private var observers: Set<AnyCancellable> = []

    init(document: Document) {
        DispatchQueue.main.async { [weak self, modelStream = document.modelStream] in
            self?.subscribe(to: modelStream)
        }
    }

    /// A vertical gray gradient, brightest overhead and darkest underfoot, used as the scene's
    /// IBL source. SceneKit treats a single image assigned to `lightingEnvironment.contents` as
    /// an equirectangular map (width = longitude, height = latitude), so it needs the usual 2:1
    /// aspect ratio even though the content only varies top-to-bottom — a badly-proportioned
    /// image samples as a near-flat average instead of a clean gradient.
    private static func makeEnvironmentImage() -> NSImage {
        let width = 256
        let height = 128
        guard let imageRep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: imageRep) else {
            return NSImage(size: CGSize(width: width, height: height))
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        let colorSpace = CGColorSpaceCreateDeviceGray()
        let stops: [(location: CGFloat, gray: CGFloat)] = [(0, 0.95), (0.55, 0.55), (1, 0.12)]
        let colors = stops.map { CGColor(colorSpace: colorSpace, components: [$0.gray, 1])! } as CFArray
        let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: stops.map(\.location))!

        context.cgContext.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: height),
            end: .zero,
            options: []
        )

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: CGSize(width: width, height: height))
        image.addRepresentation(imageRep)
        return image
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

        // A reloaded model has fresh `ModelGeometryVariant`s, so any previous build no longer applies.
        smoothGeometryBuildState = .notStarted
        modelLoadedSignal.send()
    }

    // MARK: - Shared smooth-shaded geometry

    private enum SmoothGeometryBuildState {
        case notStarted, building, done
    }
    private var smoothGeometryBuildState: SmoothGeometryBuildState = .notStarted

    /// Builds the smooth-shaded geometry for every part off the main thread (the result is cached on
    /// each shared `ModelGeometryVariant`), then notifies viewports to swap it in. Keeps large models
    /// from hitching the UI, and builds each variant once no matter how many viewports want smooth
    /// shading. Safe to call repeatedly / from multiple viewports — only the first call after a model
    /// load actually starts the build; later calls (and viewports that ask before it finishes) pick up
    /// the result via `smoothGeometryDidBuild`.
    func ensureSmoothGeometryBuilt() {
        guard smoothGeometryBuildState == .notStarted else { return }
        let variants = parts.flatMap(\.modelGeometryVariants)
        guard !variants.isEmpty else { return }
        smoothGeometryBuildState = .building
        Task.detached { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for variant in variants {
                    group.addTask { _ = variant.smoothGeometry() }
                }
            }
            await MainActor.run {
                self?.smoothGeometryBuildState = .done
                self?.smoothGeometryDidBuildSignal.send()
            }
        }
    }
}

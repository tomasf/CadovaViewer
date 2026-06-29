import AppKit
import SceneKit
import Metal
import simd
import ViewerCore

/// Document-global cache of small isometric thumbnails for each part. Because every viewport shares
/// the same master geometry, a part's thumbnail is identical across viewports, so it lives here
/// (owned by `SceneController`) rather than per-viewport.
///
/// Rendering is done lazily and off the main thread, one part at a time, as the sidebar or a context
/// menu asks for each thumbnail. Results are published on the main actor so rows refresh as renders
/// land. Entry points are all called on the main thread; the async render methods are `@MainActor`
/// so they resume there to mutate the published cache after awaiting the off-main snapshot.
final class PartThumbnailService: ObservableObject {
    /// A part thumbnail at a specific pixel size. The same part is drawn at several device-pixel
    /// footprints — the sidebar's icon-size setting (18/24/32 pt) and menu rows (24 pt), each times
    /// the display's scale — so every (part, pixel size) is rendered and cached independently. That
    /// way each consumer gets a bitmap matching its footprint exactly, with no up- or down-sampling.
    struct Key: Hashable {
        let id: ModelData.Part.ID
        let pixelSize: Int
    }

    /// Rendered thumbnails keyed by part and pixel size.
    @Published private(set) var thumbnails: [Key: NSImage] = [:]

    private var parts: [ModelData.Part.ID: ModelData.Part] = [:]
    /// The in-flight (or finished) render for each (part, pixel size), so several askers share a
    /// single render rather than each kicking off its own.
    private var renderTasks: [Key: Task<NSImage?, Never>] = [:]
    /// Serialises the actual snapshots so a many-part model doesn't swamp the GPU/CPU.
    private let renderer = ThumbnailRenderer()

    /// Re-points the service at a freshly loaded model's parts, clearing any previous thumbnails.
    func setParts(_ parts: [ModelData.Part]) {
        self.parts = Dictionary(parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        thumbnails = [:]
        for task in renderTasks.values { task.cancel() }
        renderTasks = [:]
    }

    /// The cached thumbnail for a part at `pixelSize` device pixels, kicking off an async render the
    /// first time it's requested. Synchronous for SwiftUI row bodies; rows refresh via `@Published`
    /// once the render lands. Pass `round(pointSize × displayScale)` so the bitmap matches the row's
    /// device-pixel footprint exactly.
    func thumbnail(for id: ModelData.Part.ID, pixelSize: Int) -> NSImage? {
        let key = Key(id: id, pixelSize: pixelSize)
        if let image = thumbnails[key] { return image }
        Task { _ = await renderedThumbnail(for: key) }
        return nil
    }

    /// A menu-sized copy of an already-rendered thumbnail, or nil if the part hasn't been rendered at
    /// any size yet. Lets a menu show icons for parts the sidebar has already rendered the instant it
    /// opens, since the async render (see `renderMenuIcon`) may not land before the menu is on screen.
    /// The exact-size render rarely exists on the first open (the sidebar renders at its own icon
    /// size), so fall back to the largest cached size for the part, resized; the async provider then
    /// renders and caches the pixel-perfect size.
    func cachedMenuThumbnail(for id: ModelData.Part.ID, pixelSize: Int, pointSize: CGFloat) -> NSImage? {
        let image = thumbnails[Key(id: id, pixelSize: pixelSize)] ?? largestCached(for: id)
        return image.map { sized($0, points: pointSize) }
    }

    /// The highest-resolution cached render for a part (best source to resize from), or nil if none.
    private func largestCached(for id: ModelData.Part.ID) -> NSImage? {
        thumbnails.filter { $0.key.id == id }.max { $0.key.pixelSize < $1.key.pixelSize }?.value
    }

    /// Whether a render is already cached at exactly this key (so the caller can skip re-rendering).
    func contains(_ key: Key) -> Bool { thumbnails[key] != nil }

    /// Renders a part's menu icon and caches the bitmap, returning a copy sized to `pointSize`.
    ///
    /// **Nothing here runs on the main actor**: the snapshot runs on the
    /// `ThumbnailRenderer` actor and the cache store is marshalled onto the main thread via a run-loop
    /// perform in tracking-live modes. That matters because `popUpContextMenu` spins the run loop in
    /// `NSEventTrackingRunLoopMode`, which doesn't service the main-queue (main-actor) executor — so a
    /// normal `Task { @MainActor … }` can't resume until the menu closes. Keeping off the main actor
    /// lets the icon land while the menu is open. `node` must be a clone taken on the main thread.
    func renderMenuIcon(id: ModelData.Part.ID, node: SCNNode, pixelSize: Int, pointSize: CGFloat) async -> NSImage? {
        guard let bitmap = await renderer.render(node: node, size: CGSize(width: pixelSize, height: pixelSize)) else { return nil }
        let key = Key(id: id, pixelSize: pixelSize)
        // Publish to the main-thread @Published cache in modes that stay live during menu tracking, so
        // the sidebar / next open reuse it and SwiftUI refreshes. (.common covers the non-tracking
        // case.) `service` is touched only on the main thread inside the perform block, so opt it out
        // of the Sendable check (the run-loop block is treated as `@Sendable` here).
        nonisolated(unsafe) let service = self
        RunLoop.main.perform(inModes: [.common, .eventTracking, .modalPanel]) {
            service.thumbnails[key] = bitmap
        }
        return sized(bitmap, points: pointSize)
    }

    /// The thumbnail for a part at a given pixel size, rendering it once if needed. Concurrent callers
    /// for the same (part, pixel size) await the same task.
    @MainActor
    private func renderedThumbnail(for key: Key) async -> NSImage? {
        if let image = thumbnails[key] { return image }
        if let existing = renderTasks[key] { return await existing.value }
        guard let part = parts[key.id] else { return nil }

        // Clone on the main actor (where viewports also clone the shared master); the clone shares the
        // immutable geometry, which is safe to read during the off-main render.
        let node = part.nodes.container.clone()
        let size = CGSize(width: key.pixelSize, height: key.pixelSize)
        let task = Task { await renderer.render(node: node, size: size) }
        renderTasks[key] = task
        let image = await task.value
        renderTasks[key] = nil
        if let image { thumbnails[key] = image }
        return image
    }

    /// A copy of a rendered thumbnail with its point size set for a menu row. `NSImage.size` only
    /// affects display size (the pixel representation is preserved), so the menu draws the bitmap at
    /// `points` pt — pixel-perfect when it was rendered at `points × scale` device pixels.
    private func sized(_ image: NSImage, points: CGFloat) -> NSImage {
        let copy = image.copy() as! NSImage
        copy.size = NSSize(width: points, height: points)
        return copy
    }
}

/// Serialises thumbnail snapshots onto a background executor: actor isolation means one render runs
/// at a time, so a many-part model can't kick off dozens of simultaneous GPU snapshots.
private actor ThumbnailRenderer {
    func render(node: SCNNode, size: CGSize) -> NSImage? {
        PartThumbnailRenderer.render(node: node, size: size)
    }
}

/// Renders a single part's container node to an isometric thumbnail on a transparent background.
/// Mirrors the camera/lighting setup of `OffscreenRenderer` (the Quick Look extension's whole-model
/// renderer) but scoped to one part; the two live in separate targets, so the small overlap is
/// duplicated rather than shared.
private enum PartThumbnailRenderer {
    static func render(node: SCNNode, size: CGSize) -> NSImage? {
        node.isHidden = false
        // Edges would z-fight at this size without a depth offset; faces alone read fine for a
        // thumbnail, so drop the edge group nodes (named in ModelData+Loading).
        for child in node.childNodes where child.name == "Sharp edges" || child.name == "Smooth edges" {
            child.removeFromParentNode()
        }

        let scene = SCNScene()
        scene.rootNode.addChildNode(node)

        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 30
        let ambientNode = SCNNode()
        ambientNode.light = ambientLight
        scene.rootNode.addChildNode(ambientNode)

        guard let cameraNode = makeIsometricCamera(framing: node) else { return nil }
        scene.rootNode.addChildNode(cameraNode)

        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        // Leave the scene background unset so the snapshot is transparent and blends into the
        // sidebar's material in both light and dark appearance.
        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }

    private static func makeIsometricCamera(framing node: SCNNode) -> SCNNode? {
        let (localMin, localMax) = node.boundingBox
        let transform = node.simdWorldTransform

        var minB = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var maxB = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for corner in boxCorners(min: localMin, max: localMax) {
            let world = (transform * SIMD4<Float>(corner, 1)).xyz
            minB = simd_min(minB, world)
            maxB = simd_max(maxB, world)
        }
        let size = maxB - minB
        guard size.x > 0 || size.y > 0 || size.z > 0 else { return nil }
        let center = (minB + maxB) / 2

        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        camera.fieldOfView = 30
        let fov = Float(camera.fieldOfView) * (.pi / 180)

        let distanceX = (max(size.y, size.z) / 2) / tan(fov / 2)
        let distanceY = (max(size.x, size.z) / 2) / tan(fov / 2)
        let distanceZ = (max(size.x, size.y) / 2) / tan(fov / 2)
        let isoAngle: Float = 35.264 * (.pi / 180)
        let isoDist = max(distanceX, distanceY, distanceZ)

        let position = SIMD3<Float>(
            center.x - isoDist * cos(isoAngle),
            center.y - isoDist * cos(isoAngle),
            center.z + isoDist * sin(isoAngle)
        )

        let cameraLight = SCNLight()
        cameraLight.type = .directional
        cameraLight.intensity = 800

        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.light = cameraLight
        cameraNode.simdTransform = float4x4(lookingFrom: position, at: center)
        return cameraNode
    }

    private static func boxCorners(min: SCNVector3, max: SCNVector3) -> [SIMD3<Float>] {
        [
            SIMD3(Float(min.x), Float(min.y), Float(min.z)),
            SIMD3(Float(min.x), Float(min.y), Float(max.z)),
            SIMD3(Float(min.x), Float(max.y), Float(min.z)),
            SIMD3(Float(min.x), Float(max.y), Float(max.z)),
            SIMD3(Float(max.x), Float(min.y), Float(min.z)),
            SIMD3(Float(max.x), Float(min.y), Float(max.z)),
            SIMD3(Float(max.x), Float(max.y), Float(min.z)),
            SIMD3(Float(max.x), Float(max.y), Float(max.z))
        ]
    }
}

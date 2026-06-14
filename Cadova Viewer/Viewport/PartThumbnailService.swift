import AppKit
import SceneKit
import Metal
import simd
import ViewerCore

/// Document-global cache of small isometric thumbnails for each part. Because every viewport shares
/// the same master geometry, a part's thumbnail is identical across viewports, so it lives here
/// (owned by `SceneController`) rather than per-viewport.
///
/// Rendering is done lazily and off the main thread, one part at a time, as the sidebar asks for each
/// thumbnail. Results are published back on the main thread so rows refresh as renders land.
final class PartThumbnailService: ObservableObject {
    /// Rendered thumbnails keyed by part id.
    @Published private(set) var thumbnails: [ModelData.Part.ID: NSImage] = [:]

    /// Pixel side length of the rendered image (≈3× the ~36 pt sidebar row image, for Retina).
    private let pixelSize: CGFloat = 108

    private var parts: [ModelData.Part.ID: ModelData.Part] = [:]
    /// Parts whose render has already been kicked off, so a row asking repeatedly enqueues once.
    private var requested: Set<ModelData.Part.ID> = []
    /// Serial so renders happen one at a time and don't swamp the GPU/CPU for many-part models.
    private let renderQueue = DispatchQueue(label: "se.tomasf.CadovaViewer.PartThumbnailRenderer", qos: .utility)

    /// Re-points the service at a freshly loaded model's parts, clearing any previous thumbnails.
    func setParts(_ parts: [ModelData.Part]) {
        self.parts = Dictionary(parts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        thumbnails = [:]
        requested = []
    }

    /// The cached thumbnail for a part, kicking off an async render the first time it's requested.
    /// Call from the main thread (e.g. a SwiftUI row body).
    func thumbnail(for id: ModelData.Part.ID) -> NSImage? {
        if let image = thumbnails[id] { return image }
        requestRender(id)
        return nil
    }

    private func requestRender(_ id: ModelData.Part.ID) {
        guard !requested.contains(id), let part = parts[id] else { return }
        requested.insert(id)

        // Clone on the main thread (where viewports also clone the shared master), then render the
        // private copy off-main so the expensive snapshot doesn't hitch the UI. The clone shares the
        // immutable geometry, which is safe to read concurrently with the live render.
        let node = part.nodes.container.clone()
        let size = CGSize(width: pixelSize, height: pixelSize)
        renderQueue.async { [weak self] in
            let image = PartThumbnailRenderer.render(node: node, size: size)
            DispatchQueue.main.async {
                guard let self, let image else { return }
                self.thumbnails[id] = image
            }
        }
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

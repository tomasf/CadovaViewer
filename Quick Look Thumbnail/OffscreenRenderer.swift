import Foundation
import SceneKit
import AppKit
import Metal
import ViewerCore

struct OffscreenRenderer {
    enum RenderError: Error {
        case modelLoadFailed
        case renderFailed
        case imageConversionFailed
    }

    static func renderThumbnail(
        for url: URL,
        size: CGSize,
        includeEdges: Bool = false
    ) async throws -> CGImage {
        let modelData = try await ModelData(url: url, includeEdges: includeEdges)
        return try await renderScene(with: modelData, size: size)
    }

    private static func renderScene(
        with modelData: ModelData,
        size: CGSize
    ) async throws -> CGImage {
        let scene = SCNScene()
        scene.background.contents = NSColor(white: 0.05, alpha: 1)
        scene.lightingEnvironment.contents = SceneLighting.environmentImage
        scene.rootNode.addChildNode(modelData.rootNode)

        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 30
        let ambientLightNode = SCNNode()
        ambientLightNode.light = ambientLight
        scene.rootNode.addChildNode(ambientLightNode)

        let cameraNode = setupCamera(for: modelData.rootNode, in: scene, size: size)

        let edgeNodes = modelData.parts.flatMap {
            [$0.nodes.sharpEdges, $0.nodes.smoothEdges].compactMap { $0 }
        }.flatMap { $0.childNodes { node, _ in node.geometry != nil } }

        for node in edgeNodes {
            let distanceToPart = simd_distance(cameraNode.simdWorldPosition, node.simdWorldPosition)
            node.simdWorldPosition += cameraNode.simdWorldFront * (distanceToPart / -1000.0)
        }

        let image = try renderToImage(scene: scene, pointOfView: cameraNode, size: size)

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw RenderError.imageConversionFailed
        }

        return cgImage
    }

    private static func setupCamera(for modelNode: SCNNode, in scene: SCNScene, size: CGSize) -> SCNNode {
        let (minBound, maxBound) = modelNode.boundingBox
        let boundingBox = (
            min: SIMD3<Double>(Double(minBound.x), Double(minBound.y), Double(minBound.z)),
            max: SIMD3<Double>(Double(maxBound.x), Double(maxBound.y), Double(maxBound.z))
        )
        let center = (boundingBox.min + boundingBox.max) / 2

        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        camera.fieldOfView = 30

        let axis = ViewPreset.isometric.axis
        let framing = frameBoundingBox(
            axis: axis,
            boundingBox: boundingBox,
            center: center,
            fieldOfViewDegrees: Double(camera.fieldOfView),
            aspectRatio: Double(size.width / max(size.height, 1))
        )
        let position = center + axis * framing.distance

        let cameraLight = SCNLight()
        cameraLight.type = .directional
        cameraLight.intensity = 800

        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.light = cameraLight
        cameraNode.simdTransform = float4x4(lookingFrom: SIMD3<Float>(position), at: SIMD3<Float>(center))

        scene.rootNode.addChildNode(cameraNode)

        return cameraNode
    }

    private static func renderToImage(scene: SCNScene, pointOfView: SCNNode, size: CGSize) throws -> NSImage {
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = pointOfView

        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        return image
    }
}

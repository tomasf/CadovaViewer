import Foundation
import SceneKit
import AppKit
import Metal

public struct OffscreenRenderer {
    public enum RenderError: Error {
        case modelLoadFailed
        case renderFailed
        case imageConversionFailed
    }

    public static func renderThumbnail(
        for url: URL,
        size: CGSize,
        includeEdges: Bool = false
    ) async throws -> CGImage {
        let modelData = try await ModelData(url: url, includeEdges: includeEdges)
        return try await renderScene(with: modelData, size: size)
    }

    public static func renderScene(
        with modelData: ModelData,
        size: CGSize
    ) async throws -> CGImage {
        let scene = SCNScene()
        scene.background.contents = NSColor(white: 0.05, alpha: 1)
        scene.rootNode.addChildNode(modelData.rootNode)

        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 30
        let ambientLightNode = SCNNode()
        ambientLightNode.light = ambientLight
        scene.rootNode.addChildNode(ambientLightNode)

        let cameraNode = setupCamera(for: modelData.rootNode, in: scene)

        let image = try renderToImage(scene: scene, pointOfView: cameraNode, size: size)

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw RenderError.imageConversionFailed
        }

        return cgImage
    }

    private static func setupCamera(for modelNode: SCNNode, in scene: SCNScene) -> SCNNode {
        let (minBound, maxBound) = modelNode.boundingBox
        let center = simd_float3(
            Float((minBound.x + maxBound.x) / 2),
            Float((minBound.y + maxBound.y) / 2),
            Float((minBound.z + maxBound.z) / 2)
        )

        let sizeX = Float(maxBound.x - minBound.x)
        let sizeY = Float(maxBound.y - minBound.y)
        let sizeZ = Float(maxBound.z - minBound.z)

        let camera = SCNCamera()
        camera.automaticallyAdjustsZRange = true
        camera.fieldOfView = 30

        let fovRadians = Float(camera.fieldOfView) * (.pi / 180.0)
        let objectSizeX = max(sizeY, sizeZ)
        let objectSizeY = max(sizeX, sizeZ)
        let objectSizeZ = max(sizeX, sizeY)
        let distanceX = (objectSizeX / 2) / tan(fovRadians / 2)
        let distanceY = (objectSizeY / 2) / tan(fovRadians / 2)
        let distanceZ = (objectSizeZ / 2) / tan(fovRadians / 2)

        let isoAngle: Float = 35.264 * (.pi / 180)
        let isoDist = max(distanceX, distanceY, distanceZ)

        let position = simd_float3(
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
        cameraNode.simdTransform = makeCameraTransform(position: position, target: center)

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

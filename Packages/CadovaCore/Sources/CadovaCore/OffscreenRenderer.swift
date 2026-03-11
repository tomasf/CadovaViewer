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

        setupLighting(in: scene)

        let cameraNode = setupCamera(for: modelData.rootNode, in: scene)

        let image = try renderToImage(scene: scene, pointOfView: cameraNode, size: size)

        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw RenderError.imageConversionFailed
        }

        return cgImage
    }

    private static func setupLighting(in scene: SCNScene) {
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

        let cameraNode = SCNNode()
        cameraNode.camera = camera
        cameraNode.simdTransform = makeCameraTransform(position: position, target: center)

        scene.rootNode.addChildNode(cameraNode)

        return cameraNode
    }

    private static func makeCameraTransform(position: simd_float3, target: simd_float3) -> float4x4 {
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

    private static func renderToImage(scene: SCNScene, pointOfView: SCNNode, size: CGSize) throws -> NSImage {
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = scene
        renderer.pointOfView = pointOfView

        let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
        return image
    }
}

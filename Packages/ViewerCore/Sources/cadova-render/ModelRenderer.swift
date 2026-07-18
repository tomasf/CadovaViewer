import Foundation
import SceneKit
import AppKit
import Metal
import ViewerCore

enum CameraProjection {
    case perspective
    case orthographic
}

enum EdgeVisibility: String {
    case none
    case sharp
    case all
}

enum RenderError: Error, CustomStringConvertible {
    case deviceUnavailable
    case imageEncodingFailed

    var description: String {
        switch self {
        case .deviceUnavailable: return "No Metal device is available on this system."
        case .imageEncodingFailed: return "Failed to encode the rendered image."
        }
    }
}

/// Renders a loaded model to a still image, mirroring the offscreen render pattern used by the
/// Quick Look Thumbnail extension's `OffscreenRenderer`, generalized to a configurable view preset,
/// projection, size, background, and optional grid.
enum ModelRenderer {
    static func render(
        modelData: ModelData,
        preset: ViewPreset,
        size: CGSize,
        projection: CameraProjection,
        transparent: Bool,
        backgroundColor: NSColor,
        showGrid: Bool,
        edgeVisibility: EdgeVisibility,
        margin: Double
    ) throws -> NSImage {
        let scene = SCNScene()
        scene.lightingEnvironment.contents = SceneLighting.environmentImage
        if !transparent {
            // Leaving background.contents unset (rather than setting it here) is what makes the
            // snapshot transparent - see PartThumbnailService's offscreen renderer for precedent.
            scene.background.contents = backgroundColor
        }
        scene.rootNode.addChildNode(modelData.rootNode)

        // Matches the interactive viewport's default (ViewOptions.edgeVisibility = .sharp):
        // both groups exist in the scene graph whenever edges were loaded, so hide the ones
        // that shouldn't show for the requested mode.
        for part in modelData.parts {
            part.nodes.sharpEdges?.isHidden = edgeVisibility == .none
            part.nodes.smoothEdges?.isHidden = edgeVisibility != .all
        }

        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 30
        let ambientLightNode = SCNNode()
        ambientLightNode.light = ambientLight
        scene.rootNode.addChildNode(ambientLightNode)

        let cameraNode = makeCamera(for: modelData.rootNode, in: scene, preset: preset, size: size, projection: projection, margin: margin)

        let edgeNodes = modelData.parts.flatMap {
            [$0.nodes.sharpEdges, $0.nodes.smoothEdges].compactMap { $0 }
        }.flatMap { $0.childNodes { node, _ in node.geometry != nil } }
        for node in edgeNodes {
            let distanceToPart = simd_distance(cameraNode.simdWorldPosition, node.simdWorldPosition)
            node.simdWorldPosition += cameraNode.simdWorldFront * (distanceToPart / -1000.0)
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw RenderError.deviceUnavailable
        }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode

        if showGrid {
            let grid = ViewportGrid()
            grid.updateBounds(geometry: modelData.rootNode)
            grid.showGrid = true
            grid.showOrigin = true
            scene.rootNode.addChildNode(grid.node)

            // ViewportGrid's scale/footprint math projects through the renderer (projectPoint /
            // unprojectPoint), which needs a render pass to have already established the renderer's
            // viewport - so do a throwaway snapshot first to prime it before computing the grid.
            _ = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .none)
            grid.updateVisibility(cameraNode: cameraNode)
            grid.updateScale(renderer: renderer, viewSize: size)
        }

        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }

    private static func makeCamera(
        for modelNode: SCNNode,
        in scene: SCNScene,
        preset: ViewPreset,
        size: CGSize,
        projection: CameraProjection,
        margin: Double
    ) -> SCNNode {
        let (minBound, maxBound) = modelNode.boundingBox
        let boundingBox = (
            min: SIMD3<Double>(Double(minBound.x), Double(minBound.y), Double(minBound.z)),
            max: SIMD3<Double>(Double(maxBound.x), Double(maxBound.y), Double(maxBound.z))
        )
        let center = (boundingBox.min + boundingBox.max) / 2

        let camera = SCNCamera()
        camera.fieldOfView = 30
        camera.projectionDirection = .vertical

        let axis = preset.axis
        let framing = frameBoundingBox(
            axis: axis,
            boundingBox: boundingBox,
            center: center,
            fieldOfViewDegrees: Double(camera.fieldOfView),
            aspectRatio: Double(size.width / max(size.height, 1)),
            margin: margin
        )

        switch projection {
        case .orthographic:
            camera.usesOrthographicProjection = true
            camera.orthographicScale = framing.orthographicScale
            // Matches the interactive viewport's orthographic setup (ViewportController+Projection):
            // automatic z-range doesn't behave well in orthographic mode, so use a large fixed range.
            camera.automaticallyAdjustsZRange = false
            camera.zNear = -100000
            camera.zFar = 100000
        case .perspective:
            camera.usesOrthographicProjection = false
            camera.automaticallyAdjustsZRange = true
        }

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
}

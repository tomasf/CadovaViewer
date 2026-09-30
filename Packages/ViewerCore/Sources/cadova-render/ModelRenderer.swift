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
/// Quick Look Thumbnail extension's `OffscreenRenderer`, generalized to a configurable view direction,
/// projection, size, background, and optional grid.
enum ModelRenderer {
    /// Surface shader modifier matching the viewer's "Materials" option turned off: faces go flat
    /// opaque matte white, and edge lines (flagged via `isEdgeMaterial`) go plain black, since their
    /// baked light/dark colour was chosen for contrast against the original face colour.
    private static let materialsDisabledShaderModifier = """
    #pragma arguments
    float isEdgeMaterial;
    #pragma body
    if (isEdgeMaterial > 0.5) {
        _surface.diffuse = float4(0.0, 0.0, 0.0, 1.0);
    } else {
        _surface.diffuse = float4(1.0, 1.0, 1.0, 1.0);
        _surface.metalness = 0.0;
        _surface.roughness = 0.9;
    }
    """

    static func render(
        modelData: ModelData,
        viewAxis: SIMD3<Double>,
        size: CGSize,
        projection: CameraProjection,
        transparent: Bool,
        backgroundColor: NSColor,
        showGrid: Bool,
        edgeVisibility: EdgeVisibility,
        smoothShading: Bool,
        materialsEnabled: Bool,
        hiddenPartIDs: Set<ModelData.Part.ID>,
        margin: Double
    ) throws -> NSImage {
        // Remove (rather than hide) excluded parts, so the camera framing and grid bounds, which
        // both measure the root node, only cover the parts actually rendered.
        let renderedParts = modelData.parts.filter { !hiddenPartIDs.contains($0.id) }
        for part in modelData.parts where hiddenPartIDs.contains(part.id) {
            part.nodes.container.removeFromParentNode()
        }

        if smoothShading {
            for variant in renderedParts.flatMap(\.modelGeometryVariants) {
                variant.node.geometry = variant.smoothGeometry()
            }
        }

        if !materialsEnabled {
            disableMaterials(of: renderedParts)
        }

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
        for part in renderedParts {
            part.nodes.sharpEdges?.isHidden = edgeVisibility == .none
            part.nodes.smoothEdges?.isHidden = edgeVisibility != .all
        }

        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.intensity = 30
        let ambientLightNode = SCNNode()
        ambientLightNode.light = ambientLight
        scene.rootNode.addChildNode(ambientLightNode)

        let cameraNode = makeCamera(for: modelData.rootNode, in: scene, viewAxis: viewAxis, size: size, projection: projection, margin: margin)

        let edgeNodes = renderedParts.flatMap {
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

    /// Applies `materialsDisabledShaderModifier` to every material of the given parts, flagging
    /// edge-line materials so they turn black instead of white.
    private static func disableMaterials(of parts: [ModelData.Part]) {
        func geometryNodes(under node: SCNNode?) -> [SCNNode] {
            guard let node else { return [] }
            return (node.geometry != nil ? [node] : []) + node.childNodes { child, _ in child.geometry != nil }
        }
        let edgeMaterials = parts
            .flatMap { geometryNodes(under: $0.nodes.sharpEdges) + geometryNodes(under: $0.nodes.smoothEdges) }
            .flatMap { $0.geometry?.materials ?? [] }
        let edgeMaterialIDs = Set(edgeMaterials.map(ObjectIdentifier.init))

        var faceMaterials = parts
            .flatMap { geometryNodes(under: $0.nodes.model) }
            .flatMap { $0.geometry?.materials ?? [] }
        // Smooth variants share the flat geometry's materials, but include them in case a node
        // currently holds the other variant.
        faceMaterials += parts.flatMap(\.modelGeometryVariants).flatMap(\.flat.materials)

        var seen: Set<ObjectIdentifier> = []
        for material in faceMaterials + edgeMaterials where seen.insert(ObjectIdentifier(material)).inserted {
            var modifiers = material.shaderModifiers ?? [:]
            modifiers[.surface] = materialsDisabledShaderModifier
            material.shaderModifiers = modifiers
            let isEdge = edgeMaterialIDs.contains(ObjectIdentifier(material))
            material.setValue(NSNumber(value: isEdge ? Float(1) : Float(0)), forKey: "isEdgeMaterial")
        }
    }

    private static func makeCamera(
        for modelNode: SCNNode,
        in scene: SCNScene,
        viewAxis axis: SIMD3<Double>,
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

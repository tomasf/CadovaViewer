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
        crossSections: [CrossSection],
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

        let packedPlanes = CrossSection.PackedPlanes(crossSections)
        if !materialsEnabled || !crossSections.isEmpty {
            installClipShader(on: renderedParts, planes: packedPlanes, materialsEnabled: materialsEnabled)
        }

        let scene = SCNScene()
        scene.lightingEnvironment.contents = SceneLighting.environmentImage
        if !transparent {
            // Leaving background.contents unset (rather than setting it here) is what makes the
            // snapshot transparent - see PartThumbnailService's offscreen renderer for precedent.
            scene.background.contents = backgroundColor
        }
        scene.rootNode.addChildNode(modelData.rootNode)
        addCaps(for: crossSections, of: renderedParts, planes: packedPlanes, modelSize: modelData.boundingBoxSize, materialsEnabled: materialsEnabled, to: scene)

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

    /// Installs the shared clip shader modifier on every material of the given parts: it cuts away
    /// whatever lies past the planes and, with materials off, turns faces matte white and edge lines
    /// black (edge-line materials are flagged so the shader can tell them apart).
    private static func installClipShader(on parts: [ModelData.Part], planes: CrossSection.PackedPlanes, materialsEnabled: Bool) {
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
            modifiers[.surface] = CrossSection.clipShaderModifier
            material.shaderModifiers = modifiers
            let isEdge = edgeMaterialIDs.contains(ObjectIdentifier(material))
            material.setValue(NSNumber(value: isEdge ? Float(1) : Float(0)), forKey: "isEdgeMaterial")
            material.setValue(NSNumber(value: materialsEnabled ? Float(1) : Float(0)), forKey: "materialsEnabled")
            planes.apply(to: material, skip: -1)
            // Cut parts are open, so their inside faces must draw too.
            if planes.count > 0 { material.isDoubleSided = true }
        }
    }

    /// The hatch stripe blended into cut faces: a neutral darkening, since there's no per-section
    /// colour as in the app.
    private static let capStripeColor = SCNVector4(0.15, 0.15, 0.15, 1)

    /// Adds the filled, hatched faces where each plane cuts each part, like the app's cross-section
    /// caps. Each cap is trimmed by the other planes (its own plane is skipped).
    private static func addCaps(
        for sections: [CrossSection],
        of parts: [ModelData.Part],
        planes: CrossSection.PackedPlanes,
        modelSize: SIMD3<Double>,
        materialsEnabled: Bool,
        to scene: SCNScene
    ) {
        let hatchSpacing = CrossSection.hatchSpacing(forModelSize: modelSize)
        for (index, section) in sections.prefix(CrossSection.maxRenderedCount).enumerated() {
            for part in parts {
                guard let solid = part.capSolid else { continue }
                let triangles = solid.capTriangles(planeNormal: section.normal, offset: section.plane().w)
                guard !triangles.isEmpty else { continue }

                let source = SCNGeometrySource(vertices: triangles.map { SCNVector3($0.x, $0.y, $0.z) })
                let element = SCNGeometryElement(indices: Array(UInt32(0)..<UInt32(triangles.count)), primitiveType: .triangles)
                let geometry = SCNGeometry(sources: [source], elements: [element])

                let color = part.dominantColor ?? SIMD4(0.7, 0.7, 0.7, 1)
                let hatch = section.hatchDirection
                let material = SCNMaterial()
                material.lightingModel = .constant
                material.isDoubleSided = true
                material.shaderModifiers = [.surface: CrossSection.capShaderModifier]
                material.setValue(NSValue(scnVector4: SCNVector4(color.x, color.y, color.z, 1)), forKey: "capColor")
                material.setValue(NSValue(scnVector4: capStripeColor), forKey: "capStripeColor")
                material.setValue(NSValue(scnVector3: SCNVector3(hatch.x, hatch.y, hatch.z)), forKey: "hatchDirection")
                material.setValue(NSNumber(value: hatchSpacing), forKey: "hatchSpacing")
                material.setValue(NSNumber(value: Float(0.2)), forKey: "hatchStrength")
                material.setValue(NSNumber(value: materialsEnabled ? Float(1) : Float(0)), forKey: "materialsEnabled")
                planes.apply(to: material, skip: index)
                geometry.materials = [material]

                let node = SCNNode(geometry: geometry)
                node.name = "Cross-section cap"
                scene.rootNode.addChildNode(node)
            }
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

        let distance = projection == .perspective ? framing.perspectiveDistance : framing.distance
        let position = center + axis * distance

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

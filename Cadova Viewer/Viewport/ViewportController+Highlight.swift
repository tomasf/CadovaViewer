import Cocoa
import SceneKit
import ViewerCore

/// The node name the outline mask pass draws. `applyHighlight` moves this name onto the
/// highlighted part's geometry; the `DRAW_NODE` pass in the technique renders whatever currently
/// carries it. (Category masks can't select a single part here — `SceneController` gives every
/// part the same all-bits mask — so the outline target is chosen by name instead.)
private let outlineTargetName = "OutlineTarget"

/// Outline half-thickness in points. Converted to MASK-texture pixels (× the display's backing
/// scale) in `makeOutlineTechnique`, so the outline reads the same on retina and non-retina.
private let outlineRadiusPoints: CGFloat = 5

/// Hovering a part (in the parts list) outlines it with a SceneKit post-process: a visible part
/// keeps its normal appearance and gains an outline; a hidden part is revealed as a faint
/// translucent "ghost" with the same outline so it can be located.
extension ViewportController {
    /// Reconciles the highlight to the current `highlightedPartID`: tags the part's visible
    /// geometry as the outline target (the real model for a visible part, or a freshly built
    /// ghost for a hidden one) and attaches the outline technique; clears everything when nothing
    /// is highlighted.
    func applyHighlight() {
        // Tear down the previous highlight representation.
        outlineTargetNode?.name = nil
        outlineTargetNode = nil
        highlightGhostNode?.removeFromParentNode()
        highlightGhostNode = nil

        guard let id = highlightedPartID, let part = part(withID: id) else {
            // No target: detach the technique so its DRAW_NODE mask pass doesn't fall back to
            // outlining the whole scene.
            sceneView.technique = nil
            return
        }

        let target: SCNNode
        if hiddenPartIDs.contains(id) {
            // Hidden: reveal a faint ghost and outline its fill (the real geometry is invisible).
            let ghost = makeHighlightGhost(for: part)
            privateRoot.addChildNode(ghost.root)
            highlightGhostNode = ghost.root
            target = ghost.fill
        } else if let modelNode = modelInstance.partModelNodes[id] {
            // Visible: outline this viewport's clone of the part's model node.
            target = modelNode
        } else {
            sceneView.technique = nil
            return
        }

        target.name = outlineTargetName
        outlineTargetNode = target
        // Assign a fresh technique instance each time the target changes. SceneKit caches the
        // DRAW_NODE node resolution for the lifetime of a technique object, and detaching then
        // reattaching the same object is coalesced to no change — so the outline would stay on
        // the previous part when hovering directly between two parts. A new instance re-resolves.
        sceneView.technique = makeOutlineTechnique()
    }

    /// Builds the four-pass outline technique (`Outline.metal`) and sets its colour + thickness.
    func makeOutlineTechnique() -> SCNTechnique? {
        let maskPass: [String: Any] = [
            "draw": "DRAW_NODE",
            "node": outlineTargetName,
            "program": "doesntexist",
            "metalVertexShader": "outline_mask_vertex",
            "metalFragmentShader": "outline_mask_fragment",
            "inputs": ["aPos": "vertexSymbol"],
            "outputs": ["color": "MASK"],
            "colorStates": ["clear": true, "clearColor": "0.0 0.0 0.0 0.0"]
        ]
        let dilateHPass: [String: Any] = [
            "draw": "DRAW_QUAD",
            "program": "doesntexist",
            "metalVertexShader": "outline_quad_vertex",
            "metalFragmentShader": "outline_dilate_h",
            "inputs": ["aPos": "vertexSymbol", "maskSampler": "MASK", "radius": "outlineRadiusSymbol"],
            "outputs": ["color": "MASK_H"],
            "colorStates": ["clear": true, "clearColor": "0.0 0.0 0.0 0.0"]
        ]
        let dilateVPass: [String: Any] = [
            "draw": "DRAW_QUAD",
            "program": "doesntexist",
            "metalVertexShader": "outline_quad_vertex",
            "metalFragmentShader": "outline_dilate_v",
            "inputs": ["aPos": "vertexSymbol", "maskSampler": "MASK_H", "radius": "outlineRadiusSymbol"],
            "outputs": ["color": "MASK_D"],
            "colorStates": ["clear": true, "clearColor": "0.0 0.0 0.0 0.0"]
        ]
        let outlinePass: [String: Any] = [
            "draw": "DRAW_QUAD",
            "program": "doesntexist",
            "metalVertexShader": "outline_quad_vertex",
            "metalFragmentShader": "outline_combine_fragment",
            "inputs": [
                "aPos": "vertexSymbol",
                "colorSampler": "COLOR",
                "maskSampler": "MASK",
                "dilatedSampler": "MASK_D",
                "outlineColor": "outlineColorSymbol"
            ],
            "outputs": ["color": "COLOR"],
            "colorStates": ["clear": false]
        ]
        // The mask targets track the drawable (scaleFactor 1). They can't be supersampled by
        // bumping the scaleFactor: a DRAW_NODE pass renders at the main viewport size, so the
        // silhouette would land in a corner of a larger target rather than filling it.
        let colorTarget: [String: Any] = ["type": "color", "format": "rgba8", "scaleFactor": 1]
        let dictionary: [String: Any] = [
            "passes": [
                "pass_mask": maskPass,
                "pass_dilate_h": dilateHPass,
                "pass_dilate_v": dilateVPass,
                "pass_outline": outlinePass
            ],
            "sequence": ["pass_mask", "pass_dilate_h", "pass_dilate_v", "pass_outline"],
            "symbols": [
                "outlineColorSymbol": ["type": "vec3"],
                "outlineRadiusSymbol": ["type": "float"],
                "vertexSymbol": ["semantic": "vertex"]
            ],
            "targets": ["MASK": colorTarget, "MASK_H": colorTarget, "MASK_D": colorTarget]
        ]
        guard let technique = SCNTechnique(dictionary: dictionary) else { return nil }
        technique.setValue(NSValue(scnVector3: SCNVector3(0.066, 0.208, 0.804)), forKeyPath: "outlineColorSymbol")
        // The MASK target tracks the drawable (device pixels), so convert the point-based
        // thickness to pixels with the current backing scale to keep it consistent across displays.
        let scale = sceneView.window?.backingScaleFactor ?? sceneView.layer?.contentsScale ?? 2
        technique.setValue(Float(outlineRadiusPoints * scale), forKeyPath: "outlineRadiusSymbol")
        return technique
    }

    /// A faint translucent stand-in for a hidden part: a non-occluding fill plus light edges. The
    /// geometry is rebuilt with `SCNGeometry(sources:elements:)` so it shares the original vertex
    /// buffers but carries its own material — cloning alone would mutate the real part's materials.
    /// Returns the root (to add/remove) and the fill node (which the outline traces).
    private func makeHighlightGhost(for part: ModelData.Part) -> (root: SCNNode, fill: SCNNode) {
        let root = SCNNode()
        root.name = "Highlight ghost \(part.id)"
        root.renderingOrder = 100

        let fillMaterial = SCNMaterial()
        fillMaterial.lightingModel = .constant
        fillMaterial.diffuse.contents = NSColor.white.withAlphaComponent(0.18)
        fillMaterial.transparencyMode = .singleLayer
        fillMaterial.writesToDepthBuffer = false
        fillMaterial.isDoubleSided = true

        let fill = part.nodes.model.clone()
        fill.opacity = 1
        for child in fill.childNodes {
            guard let oldGeometry = child.geometry else { continue }
            let newGeometry = SCNGeometry(sources: oldGeometry.sources(for: .vertex), elements: oldGeometry.elements)
            newGeometry.materials = [fillMaterial]
            child.geometry = newGeometry
        }
        root.addChildNode(fill)

        // Light edges, following the current edge-visibility choice.
        let edgeVisibility = sceneController.documentOptions.edgeVisibility
        let edgeSource = edgeVisibility == .all ? part.nodes.smoothEdges : part.nodes.sharpEdges
        if edgeVisibility != .none, let edgeSource {
            let edgeMaterial = SCNMaterial()
            edgeMaterial.lightingModel = .constant
            edgeMaterial.diffuse.contents = NSColor.white.withAlphaComponent(0.3)
            edgeMaterial.writesToDepthBuffer = false

            let edgeClone = edgeSource.clone()
            edgeClone.isHidden = false
            for node in edgeClone.childNodes(passingTest: { node, _ in node.geometry != nil }) {
                guard let oldGeometry = node.geometry else { continue }
                let newGeometry = SCNGeometry(sources: oldGeometry.sources(for: .vertex), elements: oldGeometry.elements)
                newGeometry.materials = [edgeMaterial]
                node.geometry = newGeometry
            }
            root.addChildNode(edgeClone)
        }

        return (root, fill)
    }
}

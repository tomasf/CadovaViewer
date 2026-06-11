import Cocoa
import SceneKit
import ViewerCore

extension ViewportController {
    var parts: [ModelData.Part] {
        sceneController.parts
    }

    var onlyVisiblePartID: ModelData.Part.ID? {
        get {
            visibleParts.count == 1 ? visibleParts.first : nil
        }
        set {
            visibleParts = newValue.map { [$0] } ?? []
        }
    }

    var hiddenPartIDs: Set<ModelData.Part.ID> {
        get { viewOptions.hiddenPartIDs }
        set { viewOptions.hiddenPartIDs = newValue }
    }

    var visibleParts: Set<ModelData.Part.ID> {
        get {
            Set(sceneController.parts.map(\.id)).subtracting(hiddenPartIDs)
        }
        set {
            hiddenPartIDs = Set(sceneController.parts.map(\.id)).subtracting(newValue)
        }
    }

    var effectivePartCounts: (visible: Int, hidden: Int) {
        sceneController.parts.reduce(into: (0,0)) { result, part in
            if hiddenPartIDs.contains(part.id) {
                result.1 += 1
            } else {
                result.0 += 1
            }
        }
    }

    func part(withID id: ModelData.Part.ID) -> ModelData.Part? {
        sceneController.parts.first(where: { $0.id == id })
    }

    func updateHighlightedPart(oldID oldValue: ModelData.Part.ID?, newID newValue: ModelData.Part.ID?) {
        // The highlight is an outline drawn by the post-process (`Outline.metal`) around the
        // hovered part. `applyHighlight` retargets it; a visible part keeps its normal look and a
        // hidden part is revealed as a faint ghost. See `ViewportController+Highlight`.
        applyHighlight()
        sceneView.render()
    }

    func updatePartNodeVisibility(_ hiddenPartIDs: Set<ModelData.Part.ID>) {
        for part in sceneController.parts {
            part.nodes.container.setVisible(!hiddenPartIDs.contains(part.id), forViewportID: categoryID)
        }
    }

    func setEdgeVisibilityInParts(_ visibility: ViewOptions.EdgeVisibility) {
        for part in sceneController.parts {
            part.nodes.sharpEdges?.isHidden = (visibility == .none)
            part.nodes.smoothEdges?.isHidden = (visibility != .all)
        }
    }

    /// Swaps every main-geometry node between its faceted (flat) geometry and a smooth-shaded
    /// variant. Turning smooth shading off is an instant main-thread swap. Turning it on builds
    /// the smooth geometry off the main thread on first use (cached thereafter), then applies the
    /// swap on the main actor, so large models don't hitch the UI.
    func setSmoothShadingInParts(_ smooth: Bool) {
        let variants = sceneController.parts.flatMap(\.modelGeometryVariants)
        guard smooth else {
            for variant in variants {
                variant.node.geometry = variant.flat
            }
            return
        }

        Task.detached {
            await withTaskGroup(of: (ModelGeometryVariant, SCNGeometry).self) { group in
                for variant in variants {
                    group.addTask { (variant, variant.smoothGeometry()) }
                }
                for await (variant, geometry) in group {
                    await MainActor.run { variant.node.geometry = geometry }
                }
            }
        }
    }
}

extension SCNNode {
    func setVisible(_ visibility: Bool, forViewportID categoryID: Int) {
        enumerateHierarchy { node, _ in
            if visibility {
                node.treeCategoryBitMask |= 1 << categoryID
            } else {
                node.treeCategoryBitMask &= ~(1 << categoryID)
            }
        }

        // This won't work with multiple viewports, but line geometries don't seem to respect categoryBitMask
        isHidden = !visibility
    }
}

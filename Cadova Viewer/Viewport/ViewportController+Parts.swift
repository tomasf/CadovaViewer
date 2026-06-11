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
        sceneView.setNeedsRedraw()
    }

    /// Per-viewport part visibility. Each viewport owns its own clone of the model, so hiding a
    /// part is a plain `isHidden` on that viewport's clone container — it doesn't touch any other
    /// viewport.
    func updatePartNodeVisibility(_ hiddenPartIDs: Set<ModelData.Part.ID>) {
        for (id, container) in modelInstance.partContainers {
            container.isHidden = hiddenPartIDs.contains(id)
        }
    }
}

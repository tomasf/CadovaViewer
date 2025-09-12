import Cocoa
import SceneKit

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
        if oldValue != nil {
            removeHighlight()
            updatePartNodeVisibility(viewOptions.hiddenPartIDs)
        }
        if let highlightedPartID, let part = part(withID: highlightedPartID) {
            updatePartNodeVisibility(viewOptions.hiddenPartIDs)
            highlightPart(part)
        }
    }

    private func highlightPart(_ part: ModelData.Part) {
        let clone = part.nodes.model.clone()
        clone.opacity = 1
        clone.name = "Highlight node"
        highlightNode = clone
        sceneController.viewportPrivateNode(for: categoryID).addChildNode(clone)
        highlightNode?.setVisible(true, forViewportID: categoryID)

        let highlight = SCNMaterial()
        highlight.lightingModel = .constant
        highlight.transparencyMode = .singleLayer
        let color1 = #colorLiteral(red: 0.3659334006, green: 0.6078522355, blue: 0.8041835711, alpha: 0.7)
        highlight.diffuse.contents = color1

        for child in clone.childNodes {
            guard let oldGeometry = child.geometry else { continue }
            let newGeometry = SCNGeometry(sources: oldGeometry.sources(for: .vertex), elements: oldGeometry.elements)
            newGeometry.materials = [highlight]
            child.geometry = newGeometry
        }

        let color2 = #colorLiteral(red: 0.3659334006, green: 0.6078522355, blue: 0.8041835711, alpha: 0.5)
        let duration = 0.4
        let action = SCNAction.customAction(duration: duration) { node, time in
            highlight.diffuse.contents = color1.blended(withFraction: time / duration, of: color2)
        }
        action.timingMode = .easeInEaseOut

        let action2 = SCNAction.customAction(duration: duration) { node, time in
            highlight.diffuse.contents = color2.blended(withFraction: time / duration, of: color1)
        }
        action2.timingMode = .easeInEaseOut

        clone.runAction(.sequence([.wait(duration: 0.3), .repeatForever(.sequence([action, action2]))]))
    }

    private func removeHighlight() {
        highlightNode?.removeFromParentNode()
        highlightNode = nil
    }

    func updatePartNodeVisibility(_ hiddenPartIDs: Set<ModelData.Part.ID>) {
        for part in sceneController.parts {
            let visibility = hiddenPartIDs.contains(part.id) == false && highlightedPartID != part.id
            part.nodes.container.setVisible(visibility, forViewportID: categoryID)
        }
    }

    func setEdgeVisibilityInParts(_ visibility: ViewOptions.EdgeVisibility) {
        for part in sceneController.parts {
            part.nodes.sharpEdges?.isHidden = (visibility == .none)
            part.nodes.smoothEdges?.isHidden = (visibility != .all)
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

import Cocoa
import SceneKit

extension ViewportController {
    func part(withID id: ModelData.Part.ID) -> ModelData.Part? {
        sceneController.parts.first(where: { $0.id == id })
    }

    func updateHighlightedPart(oldID oldValue: ModelData.Part.ID?, newID newValue: ModelData.Part.ID?) {
        if oldValue != nil {
            highlightNode?.removeFromParentNode()
            highlightNode = nil
            updatePartNodeVisibility()
        }
        if let highlightedPartID, let part = part(withID: highlightedPartID) {
            updatePartNodeVisibility()

            let clone = part.node.clone()
            clone.opacity = 1
            clone.name = "Highlight node"
            highlightNode = clone
            sceneController.viewportPrivateNode(for: categoryID).addChildNode(clone)
            highlightNode?.setVisible(true, forViewportID: categoryID)

            let highlight = SCNMaterial()
            highlight.lightingModel = .blinn
            highlight.transparencyMode = .singleLayer
            let color1 = NSColor.white.withAlphaComponent(0.7)
            highlight.diffuse.contents = color1

            guard let oldGeometry = part.node.geometry else { return }
            let newGeometry = SCNGeometry(sources: oldGeometry.sources(for: .vertex), elements: oldGeometry.elements)
            newGeometry.materials = [highlight]
            clone.geometry = newGeometry

            /*
            let highlightColor = NSColor(red: 145.0/255.0, green: 166.0/255.0, blue: 1.0, alpha: 1)
            let color2 = color1.blended(withFraction: 0.2, of: highlightColor)!
            let duration = 0.4
            let action = SCNAction.customAction(duration: duration) { node, time in
                highlight.diffuse.contents = color1.blended(withFraction: time / duration, of: color2)
            }
            action.timingMode = .easeInEaseOut

            let action2 = SCNAction.customAction(duration: duration) { node, time in
                highlight.diffuse.contents = color2.blended(withFraction: time / duration, of: color1)
            }
            clone.runAction(.repeatForever(.sequence([action, action2])))
            action2.timingMode = .easeInEaseOut
             */
        }
    }

    func updatePartNodeVisibility() {
        for part in sceneController.parts {
            let visibility = hiddenPartIDs.contains(part.id) == false && highlightedPartID == nil
            part.node.setVisible(visibility, forViewportID: categoryID)
        }
    }
}

extension SCNNode {
    func setVisible(_ visibility: Bool, forViewportID categoryID: Int) {
        enumerateHierarchy { node, _ in
            if visibility {
                node.categoryBitMask |= 1 << categoryID
            } else {
                node.categoryBitMask &= ~(1 << categoryID)
            }

            // This won't work with multiple viewports, but line geometries don't seem to respect categoryBitMask
            node.isHidden = !visibility
        }
    }
}

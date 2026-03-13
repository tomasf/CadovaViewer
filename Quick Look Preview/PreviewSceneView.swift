import SceneKit
import AppKit

class PreviewSceneView: SCNView {
    weak var modelNode: SCNNode?
    
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        
        if let modelNode = modelNode {
            let worldCenter = modelNode.convertPosition(modelNode.boundingSphere.center, to: nil)
            defaultCameraController.target = worldCenter
        }
    }
    
    override func rightMouseDown(with event: NSEvent) {
        NSEvent.overriddenModifierFlags = .option
        super.mouseDown(with: event)
        
        if let modelNode = modelNode {
            let worldCenter = modelNode.convertPosition(modelNode.boundingSphere.center, to: nil)
            defaultCameraController.target = worldCenter
        }
    }
    
    override func rightMouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
    }
    
    override func rightMouseUp(with event: NSEvent) {
        NSEvent.overriddenModifierFlags = nil
        super.mouseUp(with: event)
    }
    
    override func scrollWheel(with event: NSEvent) {
        if !event.hasPreciseScrollingDeltas {
            NSEvent.overriddenModifierFlags = .option
            super.scrollWheel(with: event)
            NSEvent.overriddenModifierFlags = nil
        } else {
            super.scrollWheel(with: event)
        }
    }
    
    override var acceptsFirstResponder: Bool { true }
}

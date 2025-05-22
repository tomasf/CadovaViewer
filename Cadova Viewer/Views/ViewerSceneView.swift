import SceneKit
import AppKit
import SwiftUI
import ObjectiveC

struct ViewerSceneView: NSViewRepresentable {
    let sceneController: ViewportController

    func makeCoordinator() -> ViewportController {
        sceneController
    }

    func makeNSView(context: Context) -> CustomSceneView {
        context.coordinator.sceneView
    }

    func updateNSView(_ sceneView: CustomSceneView, context: Context) {
        context.coordinator.updateCameraProjection()
    }
}

class CustomSceneView: SCNView {
    var onClick: ((CGPoint) -> Void)? = nil

    override init(frame: NSRect, options: [String : Any]? = nil) {
        super.init(frame: frame, options: options)
        let recognizer = NSClickGestureRecognizer(target: self, action: #selector(didClick))
        addGestureRecognizer(recognizer)
    }

    @objc
    func didClick(_ recognizer: NSClickGestureRecognizer) {
        onClick?(recognizer.location(in: self))
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        NSEvent.overriddenModifierFlags = .option
        mouseDown(with: event)
        NSEvent.overriddenModifierFlags = nil
    }

    override func rightMouseDragged(with event: NSEvent) {
        mouseDragged(with: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        mouseUp(with: event)
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
}


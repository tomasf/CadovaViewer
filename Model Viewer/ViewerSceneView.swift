import SceneKit
import AppKit
import SwiftUI
import ObjectiveC

struct ViewerSceneView: NSViewRepresentable {
    let sceneController: SceneController

    func makeCoordinator() -> SceneController {
        sceneController
    }

    func makeNSView(context: Context) -> CustomSceneView {
        context.coordinator.sceneView
    }

    func updateNSView(_ sceneView: CustomSceneView, context: Context) {
        context.coordinator.updateCamera()
    }
}

class CustomSceneView: SCNView {
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

            //guard let sceneController = delegate as? SceneController else { return }
            //sceneController.zoom(amount: event.scrollingDeltaY)
        } else {
            super.scrollWheel(with: event)
        }
    }
}

extension NSEvent {
    private static var originalGetter: IMP?

    // Set this property to swizzle +modifierFlags. Set it to nil to de-swizzle.
    static var overriddenModifierFlags: ModifierFlags? {
        didSet {
            updateSwizzle()
        }
    }

    private class func updateSwizzle() {
        if overriddenModifierFlags != nil {
            guard originalGetter == nil else { return }

            guard let originalMethod = class_getClassMethod(self, #selector(getter: modifierFlags)),
                  let newMethod = class_getClassMethod(self, #selector(getter: modifierFlags_swizzled))
            else {
                return
            }

            originalGetter = method_getImplementation(originalMethod)
            let newIMP = method_getImplementation(newMethod)
            method_setImplementation(originalMethod, newIMP)
        } else {
            guard let originalGetter else { return }

            guard let method = class_getClassMethod(self, #selector(getter: modifierFlags)) else {
                return
            }
            method_setImplementation(method, originalGetter)
            self.originalGetter = nil
        }
    }

    @objc class var modifierFlags_swizzled: ModifierFlags {
        overriddenModifierFlags ?? []
    }
}

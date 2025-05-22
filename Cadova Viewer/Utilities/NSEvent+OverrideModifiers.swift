import Foundation
import AppKit

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

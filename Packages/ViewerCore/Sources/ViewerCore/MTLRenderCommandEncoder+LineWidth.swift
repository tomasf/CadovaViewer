import Metal
import Foundation

extension MTLRenderCommandEncoder {
    /// Sets the line width via the private `setLineWidth:` selector, if the concrete encoder
    /// responds to it. Metal has no public line-width API.
    public func setLineWidthPrivate(_ width: Float) {
        guard let self = self as? NSObject,
              self.responds(to: NSSelectorFromString("setLineWidth:"))
        else { return }

        self.setValue(width, forKey: "lineWidth")
    }
}

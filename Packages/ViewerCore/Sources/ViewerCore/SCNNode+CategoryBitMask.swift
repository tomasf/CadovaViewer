import SceneKit

extension SCNNode {
    /// Sets `categoryBitMask` to `mask` on this node and every descendant.
    public func setSubtreeCategoryBitMask(_ mask: Int) {
        enumerateHierarchy { node, _ in
            node.categoryBitMask = mask
        }
    }
}

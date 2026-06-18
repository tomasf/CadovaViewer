import SceneKit
import ViewerCore

/// One viewport's private copy of the shared model.
///
/// Each viewport renders its own `SCNScene` (so it can have its own real lighting and use
/// `isHidden` for per-viewport part visibility). To avoid duplicating the heavy mesh data, the
/// node hierarchy is produced with `SCNNode.clone()`, which copies the nodes but *shares* their
/// `SCNGeometry` and materials with every other viewport's clone and with the master model.
///
/// The cross-section feature needs each viewport to clip independently, and a shader modifier's
/// clip-plane uniform is per-*material* — so a viewport must own its materials. We get that cheaply:
/// every geometry node's geometry is replaced with `SCNGeometry.copy()` (which shares the immutable
/// vertex/index buffers but takes a fresh materials array) and assigned this viewport's own copies
/// of the materials, remapped through `materialMap` so materials shared within the model stay shared
/// within the viewport. The clip uniform is then set once per unique material in `clipMaterials`.
///
/// The lookup tables below map the document's parts and the document-global geometry options onto
/// this viewport's clone nodes (the master nodes aren't in this scene, so hit testing and node
/// mutation must go through the clones).
struct ViewportModelInstance {
    /// The cloned model root, added to the viewport's scene.
    let root: SCNNode
    /// Per-part clone of the container node — toggled with `isHidden` for per-viewport visibility.
    let partContainers: [ModelData.Part.ID: SCNNode]
    /// Per-part clone of the model (face) node — the hit-test root and the outline target.
    let partModelNodes: [ModelData.Part.ID: SCNNode]
    /// Clones of the sharp / smooth edge container nodes — `isHidden` toggled for the
    /// document-global edge-visibility option.
    let sharpEdgeContainers: [SCNNode]
    let smoothEdgeContainers: [SCNNode]
    /// Clone geometry nodes carrying edge lines, for the depth offset and to exclude edges from
    /// camera-target hit testing.
    let edgeGeometryNodes: [SCNNode]
    /// This viewport's main-geometry nodes paired with the shared source variant; each swaps its
    /// node between this viewport's own flat and smooth geometry copies for the document-global
    /// smooth-shading option.
    let variantSwaps: [ViewportVariant]
    /// Every unique material in this viewport's clone (faces + edges). The cross-section clip uniform
    /// and double-sidedness are applied to these.
    let clipMaterials: [SCNMaterial]

    /// An empty instance, used before a model has loaded.
    init() {
        root = SCNNode()
        partContainers = [:]
        partModelNodes = [:]
        sharpEdgeContainers = []
        smoothEdgeContainers = []
        edgeGeometryNodes = []
        variantSwaps = []
        clipMaterials = []
    }

    init(modelData: ModelData) {
        let clone = modelData.rootNode.clone()

        // Remap shared materials to per-viewport copies, reusing one copy per original so materials
        // shared across the model stay shared within this viewport.
        var materialMap: [ObjectIdentifier: SCNMaterial] = [:]
        func mapped(_ originals: [SCNMaterial]) -> [SCNMaterial] {
            originals.map { original in
                let key = ObjectIdentifier(original)
                if let copy = materialMap[key] { return copy }
                let copy = original.copy() as! SCNMaterial
                materialMap[key] = copy
                return copy
            }
        }

        // `clone()` preserves the hierarchy structure and child order, so walk the master and the
        // clone in lockstep to map each master node to its corresponding clone node. While walking,
        // give every geometry node a per-viewport geometry copy carrying this viewport's materials.
        var map: [ObjectIdentifier: SCNNode] = [:]
        func walk(_ original: SCNNode, _ copy: SCNNode) {
            map[ObjectIdentifier(original)] = copy
            if let geometry = copy.geometry {
                let geometryCopy = geometry.copy() as! SCNGeometry
                geometryCopy.materials = mapped(geometry.materials)
                copy.geometry = geometryCopy
            }
            for (o, c) in zip(original.childNodes, copy.childNodes) { walk(o, c) }
        }
        walk(modelData.rootNode, clone)

        var partContainers: [ModelData.Part.ID: SCNNode] = [:]
        var partModelNodes: [ModelData.Part.ID: SCNNode] = [:]
        var sharpEdges: [SCNNode] = []
        var smoothEdges: [SCNNode] = []
        var edgeGeometry: [SCNNode] = []
        var swaps: [ViewportVariant] = []

        for part in modelData.parts {
            if let container = map[ObjectIdentifier(part.nodes.container)] {
                partContainers[part.id] = container
            }
            if let model = map[ObjectIdentifier(part.nodes.model)] {
                partModelNodes[part.id] = model
            }
            if let master = part.nodes.sharpEdges, let edges = map[ObjectIdentifier(master)] {
                sharpEdges.append(edges)
                edgeGeometry += edges.childNodes { node, _ in node.geometry != nil }
            }
            if let master = part.nodes.smoothEdges, let edges = map[ObjectIdentifier(master)] {
                smoothEdges.append(edges)
                edgeGeometry += edges.childNodes { node, _ in node.geometry != nil }
            }
            for variant in part.modelGeometryVariants {
                if let node = map[ObjectIdentifier(variant.node)], let flat = node.geometry {
                    swaps.append(ViewportVariant(node: node, source: variant, flat: flat))
                }
            }
        }

        root = clone
        self.partContainers = partContainers
        self.partModelNodes = partModelNodes
        self.sharpEdgeContainers = sharpEdges
        self.smoothEdgeContainers = smoothEdges
        self.edgeGeometryNodes = edgeGeometry
        self.variantSwaps = swaps
        self.clipMaterials = Array(materialMap.values)
    }
}

/// One viewport's flat/smooth geometry pair for a single main-geometry node.
///
/// The flat copy is this viewport's own (built in `ViewportModelInstance`). The smooth copy is made
/// on demand from the shared `source.smoothIfAvailable` — which is built lazily off the main thread —
/// reusing the flat copy's per-viewport materials so the clip survives a smooth-shading toggle.
final class ViewportVariant {
    let node: SCNNode
    let source: ModelGeometryVariant
    let flat: SCNGeometry
    private var smoothCopy: SCNGeometry?

    init(node: SCNNode, source: ModelGeometryVariant, flat: SCNGeometry) {
        self.node = node
        self.source = source
        self.flat = flat
    }

    /// Swaps the node to this viewport's smooth or flat geometry. Falls back to flat when the smooth
    /// source geometry hasn't been built yet (the caller re-applies once a background build lands).
    func apply(smoothShading: Bool) {
        node.geometry = geometry(smoothShading: smoothShading)
    }

    private func geometry(smoothShading: Bool) -> SCNGeometry {
        guard smoothShading, let sourceSmooth = source.smoothIfAvailable else { return flat }
        if let smoothCopy { return smoothCopy }
        let copy = sourceSmooth.copy() as! SCNGeometry
        copy.materials = flat.materials
        smoothCopy = copy
        return copy
    }
}

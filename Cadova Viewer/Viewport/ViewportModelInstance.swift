import SceneKit
import ViewerCore

/// One viewport's private copy of the shared model.
///
/// Each viewport renders its own `SCNScene` (so it can have its own real lighting and use
/// `isHidden` for per-viewport part visibility). To avoid duplicating the heavy mesh data, the
/// node hierarchy is produced with `SCNNode.clone()`, which copies the nodes but *shares* their
/// `SCNGeometry` and materials with every other viewport's clone and with the master model.
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
    /// Clone main-geometry nodes paired with the shared variant that swaps each between its flat
    /// and smooth geometry for the document-global smooth-shading option.
    let variantSwaps: [(node: SCNNode, variant: ModelGeometryVariant)]

    /// An empty instance, used before a model has loaded.
    init() {
        root = SCNNode()
        partContainers = [:]
        partModelNodes = [:]
        sharpEdgeContainers = []
        smoothEdgeContainers = []
        edgeGeometryNodes = []
        variantSwaps = []
    }

    init(modelData: ModelData) {
        let clone = modelData.rootNode.clone()

        // `clone()` preserves the hierarchy structure and child order, so walk the master and the
        // clone in lockstep to map each master node to its corresponding clone node.
        var map: [ObjectIdentifier: SCNNode] = [:]
        func walk(_ original: SCNNode, _ copy: SCNNode) {
            map[ObjectIdentifier(original)] = copy
            for (o, c) in zip(original.childNodes, copy.childNodes) { walk(o, c) }
        }
        walk(modelData.rootNode, clone)

        var partContainers: [ModelData.Part.ID: SCNNode] = [:]
        var partModelNodes: [ModelData.Part.ID: SCNNode] = [:]
        var sharpEdges: [SCNNode] = []
        var smoothEdges: [SCNNode] = []
        var edgeGeometry: [SCNNode] = []
        var swaps: [(SCNNode, ModelGeometryVariant)] = []

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
                if let node = map[ObjectIdentifier(variant.node)] {
                    swaps.append((node, variant))
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
    }
}

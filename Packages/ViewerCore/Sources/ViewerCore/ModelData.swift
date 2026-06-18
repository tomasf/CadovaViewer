import Foundation
import ThreeMF
import SceneKit
import AppKit

public struct ModelData: Sendable {
    public let rootNode: SCNNode
    public let parts: [Part]
    public let metadata: [ThreeMF.Metadata]

    /// The model's axis-aligned bounding-box size in millimetres. Spatial (does not sum across
    /// parts the way `Statistics` does), so it lives here rather than in `Statistics`.
    public let boundingBoxSize: SIMD3<Double>

    public init(rootNode: SCNNode, parts: [Part], metadata: [ThreeMF.Metadata], boundingBoxSize: SIMD3<Double> = .zero) {
        self.rootNode = rootNode
        self.parts = parts
        self.metadata = metadata
        self.boundingBoxSize = boundingBoxSize
    }

    public init() {
        self.init(rootNode: .init(), parts: [], metadata: [])
    }

    public struct Part: Identifiable, Sendable {
        public typealias ID = String

        public let nodes: Nodes

        /// The position of this part's `<item>` in the root model's build, in document order. This is
        /// how a part maps back to a specific build item when rewriting the archive (e.g. for slicing
        /// a single part) — `Part.id` can't be used for that, since it's a random UUID when the source
        /// item has no `partnumber`.
        public let itemIndex: Int

        public let name: String
        public let id: ID
        public let semantic: PartSemantic
        public let statistics: Statistics

        /// One per main-geometry node, used to swap each node between its flat geometry and a
        /// lazily-built smooth-shaded variant. Empty when smooth shading isn't applicable.
        public let modelGeometryVariants: [ModelGeometryVariant]

        /// A representative colour for the part (the colour of its largest material group), as
        /// linear RGBA. Used to fill the cross-section cap so a cut surface looks like the part's
        /// material. `nil` when the part has no drawable geometry.
        public let dominantColor: SIMD4<Float>?

        /// The part's solid geometry (world-space, millimetres) for computing the cross-section cap.
        /// `nil` when the part has no drawable geometry. See `PartSolid`.
        public let capSolid: PartSolid?

        public init(nodes: Nodes, itemIndex: Int, name: String, id: ID?, semantic: PartSemantic, stats: Statistics, modelGeometryVariants: [ModelGeometryVariant] = [], dominantColor: SIMD4<Float>? = nil, capSolid: PartSolid? = nil) {
            self.nodes = nodes
            self.itemIndex = itemIndex
            self.name = name
            self.id = id ?? UUID().uuidString
            self.semantic = semantic
            self.statistics = stats
            self.modelGeometryVariants = modelGeometryVariants
            self.dominantColor = dominantColor
            self.capSolid = capSolid
        }

        public struct Nodes: Sendable {
            public var container: SCNNode
            public var model: SCNNode
            public var sharpEdges: SCNNode?
            public var smoothEdges: SCNNode?

            public init() {
                container = SCNNode()
                model = SCNNode()
                container.addChildNode(model)
            }
        }
    }

    public var statistics: Statistics {
        .init(parts.map(\.statistics))
    }
}

extension ModelData {
    public struct Statistics: Sendable {
        public let vertexCount: Int
        public let triangleCount: Int

        /// Total surface area in mm².
        public let surfaceArea: Double
        /// Total enclosed volume in mm³ (meaningful only for watertight meshes).
        public let volume: Double

        public init(vertexCount: Int, triangleCount: Int, surfaceArea: Double = 0, volume: Double = 0) {
            self.vertexCount = vertexCount
            self.triangleCount = triangleCount
            self.surfaceArea = surfaceArea
            self.volume = volume
        }

        public init(_ stats: [Statistics]) {
            self.init(
                vertexCount: stats.map(\.vertexCount).reduce(0, +),
                triangleCount: stats.map(\.triangleCount).reduce(0, +),
                surfaceArea: stats.map(\.surfaceArea).reduce(0, +),
                volume: stats.map(\.volume).reduce(0, +)
            )
        }
    }
}

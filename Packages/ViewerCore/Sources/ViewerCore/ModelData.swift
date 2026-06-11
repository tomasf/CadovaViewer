import Foundation
import ThreeMF
import SceneKit
import AppKit

public struct ModelData: Sendable {
    public let rootNode: SCNNode
    public let parts: [Part]
    public let metadata: [ThreeMF.Metadata]

    public init(rootNode: SCNNode, parts: [Part], metadata: [ThreeMF.Metadata]) {
        self.rootNode = rootNode
        self.parts = parts
        self.metadata = metadata
    }

    public init() {
        self.init(rootNode: .init(), parts: [], metadata: [])
    }

    public struct Part: Identifiable, Sendable {
        public typealias ID = String

        public let nodes: Nodes
        public let name: String
        public let id: ID
        public let semantic: PartSemantic
        public let statistics: Statistics

        /// One per main-geometry node, used to swap each node between its flat geometry and a
        /// lazily-built smooth-shaded variant. Empty when smooth shading isn't applicable.
        public let modelGeometryVariants: [ModelGeometryVariant]

        public init(nodes: Nodes, name: String, id: ID?, semantic: PartSemantic, stats: Statistics, modelGeometryVariants: [ModelGeometryVariant] = []) {
            self.nodes = nodes
            self.name = name
            self.id = id ?? UUID().uuidString
            self.semantic = semantic
            self.statistics = stats
            self.modelGeometryVariants = modelGeometryVariants
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

        public init(vertexCount: Int, triangleCount: Int) {
            self.vertexCount = vertexCount
            self.triangleCount = triangleCount
        }

        public init(_ stats: [Statistics]) {
            self.init(
                vertexCount: stats.map(\.vertexCount).reduce(0, +),
                triangleCount: stats.map(\.triangleCount).reduce(0, +)
            )
        }
    }
}

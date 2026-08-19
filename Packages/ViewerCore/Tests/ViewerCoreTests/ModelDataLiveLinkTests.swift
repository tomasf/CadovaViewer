import Testing
import Foundation
import CadovaLiveLinkCore
@testable import ViewerCore

struct ModelDataLiveLinkTests {
    // A single flat triangle in the XY plane, 3-4-5-ish for an easy area check.
    static let triangleMessage = LiveLinkMessage(
        buildUUID: UUID(),
        path: "/tmp/livelink-test.3mf",
        parts: [
            LiveLinkMessage.Part(
                name: "Triangle",
                semantic: "solid",
                vertices: [0, 0, 0, 4, 0, 0, 0, 3, 0],
                triangles: [0, 1, 2],
                triangleMaterialIndices: [0],
                defaultMaterialIndex: 0,
                materials: [.init(color: .init(red: 255, green: 0, blue: 0, alpha: 255))]
            )
        ]
    )

    @Test func `builds one part per message part with the right geometry stats`() {
        let modelData = ModelData(liveLink: Self.triangleMessage, includeEdges: false)

        #expect(modelData.parts.count == 1)
        let part = modelData.parts[0]
        #expect(part.name == "Triangle")
        #expect(part.semantic == .solid)
        #expect(part.statistics.vertexCount == 3)
        #expect(part.statistics.triangleCount == 1)
        #expect(abs(part.statistics.surfaceArea - 6.0) < 0.001) // right triangle, legs 4 and 3
        #expect(part.hasMaterial)
        #expect(part.dominantColor != nil)
        #expect(modelData.rootNode.childNodes.count == 1)
        #expect(modelData.hasAnyMaterials)
    }

    /// The whole reason to carry the full semantic instead of an isPrintable bool: a .context part
    /// must come through as .context, not collapse into the same bucket as .visual — that's exactly
    /// the distinction a bool couldn't represent.
    @Test func `each PartSemantic case round-trips distinctly`() {
        func semantic(for rawValue: String) -> PartSemantic {
            let part = LiveLinkMessage.Part(
                name: "P", semantic: rawValue,
                vertices: Self.triangleMessage.parts[0].vertices,
                triangles: Self.triangleMessage.parts[0].triangles,
                triangleMaterialIndices: Self.triangleMessage.parts[0].triangleMaterialIndices,
                defaultMaterialIndex: nil, materials: []
            )
            let message = LiveLinkMessage(buildUUID: UUID(), path: "/tmp/t.3mf", parts: [part])
            return ModelData(liveLink: message, includeEdges: false).parts[0].semantic
        }

        #expect(semantic(for: "solid") == .solid)
        #expect(semantic(for: "context") == .context)
        #expect(semantic(for: "visual") == .visual)
        // An unrecognized value falls back to .solid, matching ThreeMF.Item.semantic's own fallback
        // for a missing/unparseable cadova:semantic attribute when loading a file.
        #expect(semantic(for: "something-a-future-Cadova-invented") == .solid)
    }

    @Test func `edge nodes are only built for a solid part`() {
        var visualPart = Self.triangleMessage.parts[0]
        visualPart = LiveLinkMessage.Part(
            name: visualPart.name, semantic: "visual",
            vertices: visualPart.vertices, triangles: visualPart.triangles,
            triangleMaterialIndices: visualPart.triangleMaterialIndices,
            defaultMaterialIndex: visualPart.defaultMaterialIndex, materials: visualPart.materials
        )
        let message = LiveLinkMessage(buildUUID: UUID(), path: Self.triangleMessage.path, parts: [visualPart])
        let modelData = ModelData(liveLink: message, includeEdges: true)

        #expect(modelData.parts[0].semantic == .visual)
        #expect(modelData.parts[0].nodes.sharpEdges == nil)
    }
}

import Testing
import Foundation
import CadovaLiveLinkCore
@testable import ViewerCore

struct ModelDataLiveLinkTests {
    // A single flat triangle in the XY plane, 3-4-5-ish for an easy area check.
    static let triangleMessage = LiveLinkMessage(
        token: UUID(),
        path: "/tmp/livelink-test.3mf",
        parts: [
            LiveLinkMessage.Part(
                name: "Triangle",
                isPrintable: true,
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

    @Test func `a non-printable part is treated as visual, not solid`() {
        var visualPart = Self.triangleMessage.parts[0]
        visualPart = LiveLinkMessage.Part(
            name: visualPart.name, isPrintable: false,
            vertices: visualPart.vertices, triangles: visualPart.triangles,
            triangleMaterialIndices: visualPart.triangleMaterialIndices,
            defaultMaterialIndex: visualPart.defaultMaterialIndex, materials: visualPart.materials
        )
        let message = LiveLinkMessage(token: UUID(), path: Self.triangleMessage.path, parts: [visualPart])
        let modelData = ModelData(liveLink: message, includeEdges: true)

        #expect(modelData.parts[0].semantic == .visual)
        // Edge nodes are only built for solid parts.
        #expect(modelData.parts[0].nodes.sharpEdges == nil)
    }
}

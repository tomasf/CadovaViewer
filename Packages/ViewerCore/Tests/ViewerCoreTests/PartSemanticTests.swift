import Testing
import Foundation
import Nodal
import ThreeMF
@testable import ViewerCore

struct PartSemanticTests {
    private let semanticName = ExpandedName(namespaceName: "https://cadova.org/3mf", localName: "semantic")

    @Test func `raw values match the wire format`() {
        #expect(PartSemantic.solid.rawValue == "solid")
        #expect(PartSemantic.context.rawValue == "context")
        #expect(PartSemantic.visual.rawValue == "visual")
    }

    @Test func `each case survives a codable round trip`() throws {
        for semantic in [PartSemantic.solid, .context, .visual] {
            let data = try JSONEncoder().encode(semantic)
            let decoded = try JSONDecoder().decode(PartSemantic.self, from: data)
            #expect(decoded == semantic)
        }
    }

    @Test func `an item without the attribute defaults to solid`() {
        let item = ThreeMF.Item(objectID: 1)
        #expect(item.semantic == .solid)
    }

    @Test func `an item parses a recognized semantic attribute`() {
        let item = ThreeMF.Item(objectID: 1, customAttributes: [semanticName: "context"])
        #expect(item.semantic == .context)

        let visual = ThreeMF.Item(objectID: 1, customAttributes: [semanticName: "visual"])
        #expect(visual.semantic == .visual)
    }

    @Test func `an unrecognized semantic value falls back to solid`() {
        let item = ThreeMF.Item(objectID: 1, customAttributes: [semanticName: "bogus"])
        #expect(item.semantic == .solid)
    }
}

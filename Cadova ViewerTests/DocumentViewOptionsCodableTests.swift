import Testing
import Foundation
@testable import CadovaViewer

struct DocumentViewOptionsCodableTests {
    @Test func `document view options round trip through codable`() throws {
        for edge in [DocumentViewOptions.EdgeVisibility.none, .sharp, .all] {
            var options = DocumentViewOptions()
            options.smoothShading = true
            options.edgeVisibility = edge

            let data = try JSONEncoder().encode(options)
            let decoded = try JSONDecoder().decode(DocumentViewOptions.self, from: data)

            #expect(decoded.smoothShading == true)
            #expect(decoded.edgeVisibility == edge)
        }
    }

    @Test func `defaults are flat shading with sharp edges`() {
        let options = DocumentViewOptions()
        #expect(options.smoothShading == false)
        #expect(options.edgeVisibility == .sharp)
    }

    @Test func `edge visibility raw values are stable`() {
        #expect(DocumentViewOptions.EdgeVisibility.none.rawValue == "none")
        #expect(DocumentViewOptions.EdgeVisibility.sharp.rawValue == "sharp")
        #expect(DocumentViewOptions.EdgeVisibility.all.rawValue == "all")
    }
}

import Testing
import Foundation
import SceneKit
@testable import CadovaViewer

struct ViewOptionsCodableTests {
    @Test func `view options survive a codable round trip`() throws {
        var options = ViewOptions()
        options.showGrid = false
        options.showOrigin = true
        options.showCoordinateSystemIndicator = false
        var transform = SCNMatrix4Identity
        transform.m11 = 2
        transform.m22 = 0.5
        transform.m41 = 5
        transform.m42 = -3
        transform.m43 = 7
        options.cameraTransform = transform
        options.hiddenPartIDs = ["part-a", "part-b"]
        options.smoothShading = true
        options.edgeVisibility = .all

        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(ViewOptions.self, from: data)

        #expect(decoded.showGrid == false)
        #expect(decoded.showOrigin == true)
        #expect(decoded.showCoordinateSystemIndicator == false)
        #expect(decoded.cameraTransform ≈ transform)
        #expect(decoded.hiddenPartIDs == ["part-a", "part-b"])
        #expect(decoded.smoothShading == true)
        #expect(decoded.edgeVisibility == .all)
    }

    @Test func `default view options round trip unchanged`() throws {
        let options = ViewOptions()
        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(ViewOptions.self, from: data)
        #expect(decoded.showGrid == options.showGrid)
        #expect(decoded.showOrigin == options.showOrigin)
        #expect(decoded.showCoordinateSystemIndicator == options.showCoordinateSystemIndicator)
        #expect(decoded.cameraTransform ≈ options.cameraTransform)
        #expect(decoded.hiddenPartIDs == options.hiddenPartIDs)
        #expect(decoded.smoothShading == options.smoothShading)
        #expect(decoded.edgeVisibility == options.edgeVisibility)
    }

    @Test func `decoding a blob without smoothShading or edgeVisibility defaults them`() throws {
        // Simulates a `ViewOptions` blob persisted before these two fields existed: encode a real
        // value, then strip the keys those old blobs wouldn't have had.
        var options = ViewOptions()
        options.smoothShading = true
        options.edgeVisibility = .all
        let data = try JSONEncoder().encode(options)
        var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "smoothShading")
        json.removeValue(forKey: "edgeVisibility")
        let strippedData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(ViewOptions.self, from: strippedData)
        #expect(decoded.smoothShading == false)
        #expect(decoded.edgeVisibility == .sharp)
    }

    @Test func `edge visibility raw values are stable`() {
        #expect(ViewOptions.EdgeVisibility.none.rawValue == "none")
        #expect(ViewOptions.EdgeVisibility.sharp.rawValue == "sharp")
        #expect(ViewOptions.EdgeVisibility.all.rawValue == "all")
    }
}

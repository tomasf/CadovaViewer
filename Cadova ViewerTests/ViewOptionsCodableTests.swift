import Testing
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

        let data = try JSONEncoder().encode(options)
        let decoded = try JSONDecoder().decode(ViewOptions.self, from: data)

        #expect(decoded.showGrid == false)
        #expect(decoded.showOrigin == true)
        #expect(decoded.showCoordinateSystemIndicator == false)
        #expect(decoded.cameraTransform ≈ transform)
        #expect(decoded.hiddenPartIDs == ["part-a", "part-b"])
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
    }
}

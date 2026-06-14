import Testing
import SceneKit
import ViewerCore
@testable import CadovaViewer

struct MeasurementTests {
    @Test func `color index wraps around the palette`() {
        let count = MeasurementPalette.entries.count
        #expect(MeasurementPalette.entry(forIndex: 0) == MeasurementPalette.entries[0])
        #expect(MeasurementPalette.entry(forIndex: count) == MeasurementPalette.entries[0])
        #expect(MeasurementPalette.entry(forIndex: count + 3) == MeasurementPalette.entries[3])
    }

    @Test func `delta is nil until an end point is set`() {
        let m = Measurement(colorIndex: 0, start: SCNVector3(1, 2, 3), end: nil, phase: .coordinate)
        #expect(m.delta == nil)
        #expect(m.length == nil)
    }

    @Test func `delta is the component-wise difference`() {
        let m = Measurement(colorIndex: 0, start: SCNVector3(1, 2, 3), end: SCNVector3(4, 6, 8), phase: .complete)
        #expect(m.delta == SCNVector3(3, 4, 5))
    }

    @Test func `length is the distance between the endpoints`() {
        let m = Measurement(colorIndex: 0, start: SCNVector3(0, 0, 0), end: SCNVector3(3, 4, 0), phase: .complete)
        #expect(m.length == 5)
    }
}

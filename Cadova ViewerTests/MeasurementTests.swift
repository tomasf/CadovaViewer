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

    @Test func `a measurement survives a json round trip`() throws {
        let m = Measurement(colorIndex: 2, start: SCNVector3(1.5, -2, 3.25), end: SCNVector3(4, 6, 8), phase: .complete)
        let data = try JSONEncoder().encode(m)
        let decoded = try JSONDecoder().decode(Measurement.self, from: data)
        #expect(decoded.colorIndex == m.colorIndex)
        #expect(decoded.start == m.start)
        #expect(decoded.end == m.end)
        #expect(decoded.phase == m.phase)
    }

    @Test func `a measurement with no end point round trips`() throws {
        let m = Measurement(colorIndex: 0, start: SCNVector3(1, 2, 3), end: nil, phase: .coordinate)
        let decoded = try JSONDecoder().decode(Measurement.self, from: try JSONEncoder().encode(m))
        #expect(decoded.start == m.start)
        #expect(decoded.end == nil)
        #expect(decoded.phase == .coordinate)
    }

    @Test func `the controller's restorable state keeps only completed measurements`() throws {
        let state = MeasurementController.RestorableState(
            measurements: [
                Measurement(colorIndex: 0, start: SCNVector3(0, 0, 0), end: SCNVector3(1, 0, 0), phase: .complete),
                Measurement(colorIndex: 1, start: SCNVector3(2, 0, 0), end: SCNVector3(5, 4, 0), phase: .complete),
            ],
            nextColorIndex: 2
        )
        let decoded = try JSONDecoder().decode(MeasurementController.RestorableState.self, from: try JSONEncoder().encode(state))
        #expect(decoded.measurements.count == 2)
        #expect(decoded.nextColorIndex == 2)
        #expect(decoded.measurements.last?.length == 5)
    }
}

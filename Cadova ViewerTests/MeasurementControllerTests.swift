import Testing
import SceneKit
import ViewerCore
@testable import CadovaViewer

@MainActor
struct MeasurementControllerTests {
    private func makeController() -> MeasurementController {
        let controller = MeasurementController()
        controller.interactionMode = .measure
        return controller
    }

    @Test func `committing the first point starts a length measurement`() {
        let controller = makeController()
        controller.commitPoint(at: SCNVector3(1, 0, 0))
        #expect(controller.measurements.count == 1)
        #expect(controller.measurements[0].phase == .lengthInProgress)
        #expect(controller.measurements[0].end == nil)
        #expect(controller.inProgressStart == SCNVector3(1, 0, 0))
    }

    @Test func `committing the second point completes the measurement`() {
        let controller = makeController()
        controller.commitPoint(at: SCNVector3(0, 0, 0))
        controller.commitPoint(at: SCNVector3(0, 5, 0))
        #expect(controller.measurements.count == 1)
        #expect(controller.measurements[0].phase == .complete)
        #expect(controller.measurements[0].end == SCNVector3(0, 5, 0))
        #expect(controller.inProgressStart == nil)
    }

    @Test func `hover before the first click shows a preview`() {
        let controller = makeController()
        controller.hover(at: SCNVector3(2, 2, 2))
        #expect(controller.hoverPreview != nil)
        #expect(controller.hoverPreview?.start == SCNVector3(2, 2, 2))
        #expect(controller.measurements.isEmpty)
    }

    @Test func `hover updates the in-progress end point`() {
        let controller = makeController()
        controller.commitPoint(at: SCNVector3(0, 0, 0))
        controller.hover(at: SCNVector3(3, 0, 0))
        #expect(controller.measurements[0].end == SCNVector3(3, 0, 0))
    }

    @Test func `leaving measure mode cancels the in-progress measurement`() {
        let controller = makeController()
        controller.commitPoint(at: SCNVector3(0, 0, 0))
        controller.interactionMode = .view
        #expect(controller.measurements.isEmpty)
    }

    @Test func `cancel removes the in-progress measurement`() {
        let controller = makeController()
        controller.commitPoint(at: SCNVector3(0, 0, 0))
        controller.cancelInProgress()
        #expect(controller.measurements.isEmpty)
    }

    @Test func `commit and hover are ignored outside measure mode`() {
        let controller = MeasurementController() // defaults to .view
        controller.commitPoint(at: SCNVector3(0, 0, 0))
        controller.hover(at: SCNVector3(1, 1, 1))
        #expect(controller.measurements.isEmpty)
        #expect(controller.hoverPreview == nil)
    }

    @Test func `delete removes a single measurement`() {
        let controller = makeController()
        controller.commitPoint(at: SCNVector3(0, 0, 0))
        controller.commitPoint(at: SCNVector3(1, 0, 0))
        let id = controller.measurements[0].id
        controller.delete(id)
        #expect(controller.measurements.isEmpty)
    }

    @Test func `delete all clears every measurement`() {
        let controller = makeController()
        controller.commitPoint(at: SCNVector3(0, 0, 0))
        controller.commitPoint(at: SCNVector3(1, 0, 0))
        controller.commitPoint(at: SCNVector3(2, 0, 0))
        controller.commitPoint(at: SCNVector3(3, 0, 0))
        controller.deleteAll()
        #expect(controller.measurements.isEmpty)
    }

    // MARK: - Undo

    /// Runs `body` inside its own explicit undo group so each operation is undoable
    /// on its own (there is no run loop to auto-close event groups in tests).
    private func group(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    @Test func `undo restores the state before completing a measurement`() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let controller = makeController()
        controller.undoManager = undo

        group(undo) { controller.commitPoint(at: SCNVector3(0, 0, 0)) }
        group(undo) { controller.commitPoint(at: SCNVector3(0, 5, 0)) }
        #expect(controller.measurements[0].phase == .complete)

        undo.undo()
        #expect(controller.measurements.count == 1)
        #expect(controller.measurements[0].phase == .lengthInProgress)
        #expect(controller.measurements[0].end == nil)
    }

    @Test func `redo re-applies an undone deletion`() {
        let undo = UndoManager()
        undo.groupsByEvent = false
        let controller = makeController()
        controller.undoManager = undo

        group(undo) { controller.commitPoint(at: SCNVector3(0, 0, 0)) }
        group(undo) { controller.commitPoint(at: SCNVector3(1, 0, 0)) }
        let id = controller.measurements[0].id

        group(undo) { controller.delete(id) }
        #expect(controller.measurements.isEmpty)

        undo.undo()
        #expect(controller.measurements.count == 1)

        undo.redo()
        #expect(controller.measurements.isEmpty)
    }
}

import Foundation
import SceneKit
import Combine
import AppKit
import simd
import ViewerCore

/// Owns the document-global measurement state: the committed measurements, the in-progress/hover
/// preview, the interaction mode, the sidebar highlight, and undo. It is fed world-space points by
/// whichever viewport the pointer is over (it does no hit testing itself), and holds no 3D
/// geometry — each viewport's `MeasurementRenderer` observes this controller and draws the
/// measurements in its own scene. Because the state is shared, a measurement can be started in one
/// viewport and finished in another.
final class MeasurementController: ObservableObject {
    enum Change {
        case live(sourceViewportID: UUID?)
        case structural
        case highlight
    }

    @Published var interactionMode: InteractionMode = .view {
        didSet {
            guard interactionMode != oldValue else { return }
            if interactionMode != .measure {
                cancelInProgress()
            }
        }
    }

    /// Committed measurements, in creation order. The last one may be in progress.
    @Published private(set) var measurements: [Measurement] = []

    /// Transient measurement following the cursor before the first click. Not yet committed.
    @Published private(set) var hoverPreview: Measurement?

    /// Measurement currently highlighted from the sidebar; its dots/line are emphasized in every
    /// viewport.
    @Published var highlightedID: Measurement.ID? {
        didSet { if highlightedID != oldValue { didChange.send(.highlight) } }
    }

    /// Fires synchronously after the measurement state changes (a point moved, a measurement was
    /// added/removed, the highlight changed). Each viewport's `MeasurementRenderer` reconciles on
    /// it in the same runloop turn, so the geometry tracks the cursor without a frame of lag.
    let didChange = PassthroughSubject<Change, Never>()

    /// Whether the pointer is over the sidebar list. While true the model hover is ignored so
    /// moving over the list doesn't drive the measurement preview.
    @Published var isPointerOverList = false {
        didSet {
            guard isPointerOverList, isPointerOverList != oldValue else { return }
            hover(at: nil)
        }
    }

    private var nextColorIndex = 0

    /// Undo manager for measurement operations (the document's dedicated one). Held weakly
    /// because it strong-references this controller as the undo target.
    weak var undoManager: UndoManager?

    // MARK: - Interaction

    func hover(at worldPoint: SCNVector3?, centered: Bool = false, sourceViewportID: UUID? = nil) {
        guard interactionMode == .measure else { return }

        if let index = inProgressIndex {
            setInProgressPoints(end: worldPoint, centered: centered, at: index)
        } else if let worldPoint {
            if hoverPreview != nil {
                hoverPreview?.start = worldPoint
            } else {
                hoverPreview = Measurement(colorIndex: nextColorIndex, start: worldPoint, end: nil, phase: .coordinate)
            }
        } else {
            clearHoverPreview()
        }
        didChange.send(.live(sourceViewportID: sourceViewportID))
    }

    func commitPoint(at worldPoint: SCNVector3, centered: Bool = false) {
        guard interactionMode == .measure else { return }

        if let index = inProgressIndex {
            let anchor = inProgressAnchor
            setInProgressPoints(end: worldPoint, centered: centered, at: index)
            measurements[index].phase = .complete

            // Undo of completing a measurement returns to the state after the first
            // click: anchor fixed, endpoint not yet set. Centering moved the start off the
            // anchor, so put it back rather than snapshotting the mirrored point.
            var before = measurements
            before[index].start = anchor ?? before[index].start
            before[index].end = nil
            before[index].phase = .lengthInProgress
            registerUndo(toRestore: Snapshot(measurements: before, nextColorIndex: nextColorIndex), actionName: "Set Measurement Endpoint")

            inProgressAnchor = nil

            // A measurement is a one-shot action: once it's finished, drop back to view mode so the
            // pointer goes straight back to orbiting. (Safe to do here — the measurement is now
            // `.complete`, so the mode change's `cancelInProgress` has nothing to remove.)
            interactionMode = .view
        } else {
            clearHoverPreview()
            let before = Snapshot(measurements: measurements, nextColorIndex: nextColorIndex)
            let measurement = Measurement(colorIndex: nextColorIndex, start: worldPoint, end: nil, phase: .lengthInProgress)
            nextColorIndex += 1
            measurements.append(measurement)
            inProgressAnchor = worldPoint
            registerUndo(toRestore: before, actionName: "Set Measurement Start Point")
        }
        didChange.send(.structural)
    }

    /// Cancels an in-progress length measurement (Escape, or leaving measure mode).
    func cancelInProgress() {
        clearHoverPreview()
        if let index = inProgressIndex {
            measurements.remove(at: index)
        }
        inProgressAnchor = nil
        didChange.send(.structural)
    }

    /// Places the moving end of the in-progress measurement at `index`. Normally the start stays
    /// on the anchor (the first clicked point); when `centered`, the start is mirrored through the
    /// anchor instead, so the two endpoints sit at equal distances from it in opposite directions.
    private func setInProgressPoints(end worldPoint: SCNVector3?, centered: Bool, at index: Int) {
        guard let anchor = inProgressAnchor else { return }
        measurements[index].end = worldPoint
        measurements[index].start = centered ? (worldPoint?.mirrored(about: anchor) ?? anchor) : anchor
    }

    func delete(_ id: Measurement.ID) {
        restore(Snapshot(measurements: measurements.filter { $0.id != id }, nextColorIndex: nextColorIndex), actionName: "Delete Measurement")
    }

    func deleteAll() {
        restore(Snapshot(measurements: [], nextColorIndex: 0), actionName: "Delete All Measurements")
    }

    // MARK: - State restoration

    /// The committed measurement state persisted in the document's restorable state.
    struct RestorableState: Codable {
        var measurements: [Measurement]
        var nextColorIndex: Int
    }

    /// A snapshot of the *finished* measurements for restoration. The transient in-progress one (and
    /// the hover preview) is excluded so a reopened document only restores completed measurements.
    var restorableState: RestorableState {
        RestorableState(measurements: measurements.filter { $0.phase == .complete }, nextColorIndex: nextColorIndex)
    }

    /// Replaces the measurement state from a restored snapshot. Not undoable (state restoration runs
    /// before the user can act, and shouldn't seed the undo stack).
    func loadRestorableState(_ state: RestorableState) {
        measurements = state.measurements
        nextColorIndex = state.nextColorIndex
        inProgressAnchor = nil // only completed measurements are persisted
        hoverPreview = nil
        highlightedID = nil
        didChange.send(.structural)
    }

    private var inProgressIndex: Int? {
        guard let last = measurements.indices.last, measurements[last].phase == .lengthInProgress else { return nil }
        return last
    }

    /// The fixed first point of the in-progress length measurement, if any: the origin of the
    /// axis constraint and the point a centered measurement is symmetric about. Tracked
    /// separately from the measurement's `start` because centering moves `start` off it (see
    /// `setInProgressPoints`).
    private(set) var inProgressAnchor: SCNVector3?

    private func clearHoverPreview() {
        guard hoverPreview != nil else { return }
        hoverPreview = nil
    }

    // MARK: - Undo

    /// Undoable snapshot of the committed measurement state.
    private struct Snapshot {
        var measurements: [Measurement]
        var nextColorIndex: Int
    }

    private func registerUndo(toRestore snapshot: Snapshot, actionName: String) {
        undoManager?.registerUndo(withTarget: self) { controller in
            controller.restore(snapshot, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    /// Replaces the committed measurements with `snapshot`, registering the inverse so
    /// NSUndoManager can ping-pong between undo and redo.
    private func restore(_ snapshot: Snapshot, actionName: String) {
        registerUndo(toRestore: Snapshot(measurements: measurements, nextColorIndex: nextColorIndex), actionName: actionName)

        measurements = snapshot.measurements
        nextColorIndex = snapshot.nextColorIndex
        // A restored in-progress measurement always has its endpoint unset, so its `start` is
        // the anchor — centering only ever moves `start` once an endpoint exists.
        inProgressAnchor = inProgressIndex.map { measurements[$0].start }
        hoverPreview = nil
        if let id = highlightedID, !measurements.contains(where: { $0.id == id }) {
            highlightedID = nil
        }
        didChange.send(.structural)
    }
}

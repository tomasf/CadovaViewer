import Foundation
import ViewerCore

extension ViewportController {
    func viewDidChange() {
        if cameraNode.camera == nil {
            return
        }
        // The camera transform is persisted only for state restoration; nothing reads the live
        // value. It's captured lazily from the camera node at save time (see
        // `viewOptionsForStateRestoration`) rather than written into the @Published `viewOptions`
        // here. Publishing it every navigation frame fired `objectWillChange` each frame - which the
        // view model re-broadcasts to the whole document UI - making per-frame SwiftUI re-evaluation
        // dominate main-thread time and stutter SpaceMouse navigation. So just flag the document
        // dirty (coalesced to one deferred call) so the new camera position is saved once motion
        // settles.
        scheduleRestorableStateInvalidation()

        // The toolbar's roll/preset enabled state isn't needed until navigation finishes, and
        // recomputing + publishing it every motion frame is wasteful (each publish repaints the
        // toolbar, and `canShowViewPreset` walks the model bounds). `viewDidChange` fires on each
        // `motionActiveChanged(false)`, which recurs throughout a continuous gesture, so debounce:
        // (re)arm a settle timer here and only refresh once motion has been quiet for a beat.
        scheduleNavigationSettledUpdate()
    }

    /// (Re)arms the settle timer. Each `viewDidChange` pushes it back, so the refresh lands only
    /// after motion stops; `motionActiveChanged(true)` cancels it when a new gesture begins.
    func scheduleNavigationSettledUpdate() {
        navigationSettleWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.updateNavigationDependentState() }
        navigationSettleWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.navigationSettleDelay, execute: work)
    }

    /// Cancels a pending settle refresh because navigation has resumed.
    func cancelNavigationSettledUpdate() {
        navigationSettleWorkItem?.cancel()
        navigationSettleWorkItem = nil
    }

    private func updateNavigationDependentState() {
        let canReset = canResetRoll()
        if canReset != canResetCameraRoll {
            canResetCameraRoll = canReset
        }

        let presetFlags = Dictionary(uniqueKeysWithValues: ViewPreset.allCases.map {
            ($0, canShowViewPreset($0))
        })
        if canShowPresets != presetFlags {
            canShowPresets = presetFlags
        }
    }

    /// Marks the document's restorable state dirty, coalescing the many per-frame requests during
    /// navigation into a single deferred call. Main-thread only (all `viewDidChange` callers are).
    func scheduleRestorableStateInvalidation() {
        if restorableStateInvalidationScheduled { return }
        restorableStateInvalidationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            restorableStateInvalidationScheduled = false
            document?.invalidateRestorableState()
        }
    }
}

import AppKit
import Foundation

extension ViewportController {
    /// `viewOptions` with the live camera transform folded in, for state capture. The transform is
    /// deliberately kept out of the per-frame `@Published` path (see `viewDidChange`), so it's read
    /// straight from the camera node whenever the layout is actually snapshotted.
    var viewOptionsForStateRestoration: ViewOptions {
        var options = viewOptions
        options.cameraTransform = cameraNode.transform
        return options
    }

    func setViewOptions(_ viewOptions: ViewOptions) {
        self.viewOptions = viewOptions
        grid.showGrid = viewOptions.showGrid
        grid.showOrigin = viewOptions.showOrigin
        cameraNode.transform = viewOptions.cameraTransform
        updatePartNodeVisibility(viewOptions.hiddenPartIDs)
        hasSetInitialView = true
        Preferences().viewOptions = viewOptions
    }

    /// Makes this the document's focused viewport (menu/toolbar/NavLib commands act on it). Called
    /// when the scene view is clicked.
    func requestFocus() {
        documentViewModel?.focus(viewportID)
    }

    /// Releases the viewport before it's discarded (on close): stop NavLib motion and drop the
    /// notification/Combine subscriptions. The shared scene's private node is removed by the
    /// document view model. The controller then deallocates with its scene view and NavLib session.
    func tearDown() {
        setNavLibSuspended(true)
        stopCameraInertia()
        observers.removeAll()
        if let modifierFlagsMonitor { NSEvent.removeMonitor(modifierFlagsMonitor) }
        modifierFlagsMonitor = nil
        // Undo actions strong-reference this controller as their target; drop a closed viewport's so
        // it isn't kept alive (and stale cross-section undos for it can't fire).
        document?.interactionUndoManager.removeAllActions(withTarget: self)
    }

    func showSceneKitRenderingOptions() {
        let panelClass: AnyObject? = NSClassFromString("SCNRendererOptionsPanel")
        let panel = panelClass?.perform(NSSelectorFromString("rendererOptionsPanelForView:"), with: sceneView).takeUnretainedValue() as? NSPanel
        panel?.hidesOnDeactivate = true
        panel?.isFloatingPanel = true
        panel?.makeKeyAndOrderFront(nil)
    }
}

import Foundation
import AppKit
import SwiftUI

class DocumentHostingController: NSHostingController<DocumentView>, NSMenuItemValidation {
    let viewModel: DocumentViewModel
    var sceneController: SceneController { viewModel.sceneController }
    /// The undo manager for in-view interactions (measurements, cross-sections). Exposed through the
    /// responder chain so Edit ▸ Undo/Redo (⌘Z/⌘⇧Z) drive it — nothing else in the chain implements
    /// `undo:`/`redo:`, so without this they'd stay greyed out.
    private let interactionUndoManager: UndoManager

    init(document: Document) {
        viewModel = DocumentViewModel(document: document)
        interactionUndoManager = document.interactionUndoManager

        super.init(rootView: DocumentView(url: document.fileURL!, errorHandler: { [weak document] error in
            document?.presentError(error)
        }, viewModel: viewModel))
    }

    override var undoManager: UndoManager? { interactionUndoManager }

    @objc func undo(_ sender: Any?) { interactionUndoManager.undo() }
    @objc func redo(_ sender: Any?) { interactionUndoManager.redo() }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The viewport that menu-bar commands act on (the focused one).
    var viewportController: ViewportController { viewModel.focusedViewport }

    @objc func removeAllMeasurements(_ sender: Any?) {
        viewModel.measurements.deleteAll()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undo(_:)):
            menuItem.title = interactionUndoManager.canUndo ? interactionUndoManager.undoMenuItemTitle : "Undo"
            return interactionUndoManager.canUndo
        case #selector(redo(_:)):
            menuItem.title = interactionUndoManager.canRedo ? interactionUndoManager.redoMenuItemTitle : "Redo"
            return interactionUndoManager.canRedo
        case #selector(removeAllMeasurements(_:)):
            return !viewModel.measurements.measurements.isEmpty
        default:
            return true
        }
    }

    func buildMenu(_ type: MenuType, with menuBuilder: MenuBuilder) {
        switch type {
        case .file:
            viewModel.focusedViewport.buildFileMenu(with: menuBuilder)
        case .view:
            viewModel.focusedViewport.buildViewMenu(with: menuBuilder)
        case .window:
            viewModel.focusedViewport.buildWindowMenu(with: menuBuilder)
        }
    }
}

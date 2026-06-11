import Foundation
import AppKit
import SwiftUI

enum GlobalCategoryMasks: Int {
    case universal = 1
}

class DocumentHostingController: NSHostingController<DocumentView>, NSMenuItemValidation {
    let viewModel: DocumentViewModel
    var sceneController: SceneController { viewModel.sceneController }

    init(document: Document) {
        viewModel = DocumentViewModel(document: document)

        super.init(rootView: DocumentView(url: document.fileURL!, errorHandler: { [weak document] error in
            document?.presentError(error)
        }, viewModel: viewModel))
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The viewport that menu-bar commands act on (the focused one).
    var viewportController: ViewportController { viewModel.focusedViewport }

    @objc func removeAllMeasurements(_ sender: Any?) {
        viewModel.focusedViewport.measurementController.deleteAll()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(removeAllMeasurements(_:)) {
            return !viewModel.focusedViewport.measurementController.measurements.isEmpty
        }
        return true
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

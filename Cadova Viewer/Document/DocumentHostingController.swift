import Foundation
import AppKit
import SwiftUI

enum GlobalCategoryMasks: Int {
    case universal = 1
}

class DocumentHostingController: NSHostingController<DocumentView>, NSMenuItemValidation {
    var viewportControllers: [ViewportController] = []
    let sceneController: SceneController

    private var usedCategoryMasks = GlobalCategoryMasks.universal.rawValue

    init(document: Document) {
        sceneController = SceneController(document: document)

        let viewportID = (~usedCategoryMasks).trailingZeroBitCount
        let privateContainer = sceneController.viewportPrivateNode(for: viewportID)
        let viewportController = ViewportController(document: document, sceneController: sceneController, categoryID: viewportID, privateContainer: privateContainer)
        usedCategoryMasks |= (1 << viewportID)
        viewportControllers.append(viewportController)

        super.init(rootView: DocumentView(url: document.fileURL!, errorHandler: { [weak document] error in
            document?.presentError(error)
        }, viewportController: viewportController))
    }

    private var nextUnusedCategoryIndex: Int {
        (~usedCategoryMasks).trailingZeroBitCount
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var viewportController: ViewportController {
        viewportControllers[0] // Remove this hack once we have support for multiple viewports
    }

    @objc func removeAllMeasurements(_ sender: Any?) {
        viewportController.measurementController.deleteAll()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(removeAllMeasurements(_:)) {
            return !viewportController.measurementController.measurements.isEmpty
        }
        return true
    }

    func buildMenu(_ type: MenuType, with menuBuilder: MenuBuilder) {
        switch type {
        case .file:
            viewportController.buildFileMenu(with: menuBuilder)
        case .view:
            viewportController.buildViewMenu(with: menuBuilder)
        case .window:
            viewportController.buildWindowMenu(with: menuBuilder)
        }
    }
}

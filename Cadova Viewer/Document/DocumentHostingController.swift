import Foundation
import AppKit
import SwiftUI

enum GlobalCategoryMasks: Int {
    case universal = 1
}

class DocumentHostingController: NSHostingController<DocumentView> {
    var viewportControllers: [ViewportController] = []
    let sceneController: SceneController

    private var usedCategoryMasks = GlobalCategoryMasks.universal.rawValue

    init(document: Document) {
        sceneController = SceneController(document: document)

        let viewportID = (~usedCategoryMasks).trailingZeroBitCount //nextUnusedCategoryIndex
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

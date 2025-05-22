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
        viewportControllers[0] // Remove this hack once we have proper support for multiple viewports
    }

    @IBAction func performSceneControllerMenuCommand(_ sender: NSMenuItem) {
        guard let identifier = sender.identifier?.rawValue, let command = ViewportController.MenuCommand(rawValue: identifier) else {
            preconditionFailure("Invalid command")
        }
        viewportController.performMenuCommand(command, tag: sender.tag)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performSceneControllerMenuCommand(_:)),
           let identifier = menuItem.identifier?.rawValue,
           let command = ViewportController.MenuCommand(rawValue: identifier)
        {
            return viewportController.canPerformMenuCommand(command, tag: menuItem.tag)
        } else {
            return true
        }
    }
}

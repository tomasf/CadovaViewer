import Cocoa
import UniformTypeIdentifiers
import SceneKit
import SceneKit.ModelIO
import ModelIO
import SwiftUI
import Combine
import ThreeMF
import Zip

class Document: NSDocument, NSWindowDelegate {
    typealias ModelStream = AnyPublisher<ModelData, Never>
    var modelSubject: CurrentValueSubject<ModelData, Never> = .init(ModelData(rootNode: .init(), parts: []))

    var modelStream: ModelStream {
        modelSubject.eraseToAnyPublisher()
    }

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool {
        true
    }

    override func makeWindowControllers() {
        let viewController = DocumentHostingController(document: self)
        let window = NSWindow(contentViewController: viewController)
        let windowController = NSWindowController(window: window)
        window.delegate = self
        //window.toolbarStyle = .expanded
        self.addWindowController(windowController)
    }

    override func read(from url: URL, ofType typeName: String) throws {
        do {
            let threeMF = try PackageReader(url: url)
            let start = CFAbsoluteTimeGetCurrent()
            modelSubject.value = try threeMF.sceneKitNode()
            let end = CFAbsoluteTimeGetCurrent()
            Swift.print("Loading time: \(end - start)")
        } catch {
            Swift.print("Error: \(error)")
            throw error
        }
    }

    override func presentedItemDidChange() {
        super.presentedItemDidChange()

        guard let fileURL, let fileType else { return }
        let diskModificationDate = try? FileManager().attributesOfItem(atPath: fileURL.path())[.modificationDate] as? Date
        let lastKnownModificationDate = fileModificationDate

        guard let diskModificationDate, let lastKnownModificationDate, diskModificationDate > lastKnownModificationDate else {
            return // Item on disk was unchanged
        }

        DispatchQueue.main.async {
            do {
                try self.revert(toContentsOf: fileURL, ofType: fileType)
            } catch(let error as ZipError) {
                // Ignore Zip errors while auto-reading. This can be due to half-written Zip archives
                Swift.print("Failed to auto-read archive: \(error)")
            } catch {
                self.presentError(error)
            }
        }
    }

    enum Error: Swift.Error {
        case invalidDocument
    }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        proposedOptions.union(.autoHideToolbar)
    }
}

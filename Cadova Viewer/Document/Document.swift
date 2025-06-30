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
    private let modelSubject: CurrentValueSubject<ModelData, Never> = .init(ModelData(rootNode: .init(), parts: []))
    private let loadingSubject: CurrentValueSubject<Bool, Never> = .init(false)

    var modelStream: AnyPublisher<ModelData, Never> { modelSubject.eraseToAnyPublisher() }
    var loadingStream: AnyPublisher<Bool, Never> { loadingSubject.eraseToAnyPublisher() }

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
            loadingSubject.send(true)
            let threeMF = try PackageReader(url: url)
            let start = CFAbsoluteTimeGetCurrent()
            modelSubject.value = try threeMF.modelData()
            loadingSubject.send(false)
            let end = CFAbsoluteTimeGetCurrent()
            Swift.print("Loading time: \(end - start)")
        } catch {
            Swift.print("Error: \(error)")
            throw error
        }
    }

    private var documentHostingController: DocumentHostingController? {
        windowControllers.first?.contentViewController as? DocumentHostingController
    }

    private static let viewOptionsKey = "viewOptions"

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        guard let viewOptions = documentHostingController?.viewportController.viewOptions,
              let data = try? JSONEncoder().encode(viewOptions)
        else { return }

        coder.encode(data, forKey: Self.viewOptionsKey)
    }

    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        if let data = coder.decodeObject(forKey: Self.viewOptionsKey) as? Data,
           let viewOptions = try? JSONDecoder().decode(ViewportController.ViewOptions.self, from: data)
        {
            documentHostingController?.viewportController.setViewOptions(viewOptions)
        }
    }

    override class func allowedClasses(forRestorableStateKeyPath keyPath: String) -> [AnyClass] {
        [NSData.self]
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

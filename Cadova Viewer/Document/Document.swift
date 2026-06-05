import Cocoa
import UniformTypeIdentifiers
import SceneKit
import SceneKit.ModelIO
import ModelIO
import SwiftUI
import Combine
import ThreeMF
import Zip
import ViewerCore

class Document: NSDocument, NSWindowDelegate {
    private let modelSubject: CurrentValueSubject<ModelData, Never> = .init(ModelData())
    private let loadingSubject: CurrentValueSubject<Bool, Never> = .init(false)

    var modelStream: AnyPublisher<ModelData, Never> {
        modelSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    var loadingStream: AnyPublisher<Bool, Never> {
        loadingSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    /// Dedicated undo manager for measurement operations. Kept separate from the document's
    /// own `undoManager` so registering measurement undos doesn't mark the (read-only)
    /// document as edited. Vended to the window below so Edit ▸ Undo/Redo (⌘Z/⌘⇧Z) use it.
    let measurementUndoManager = UndoManager()

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool {
        true
    }

    override func makeWindowControllers() {
        let viewController = DocumentHostingController(document: self)
        let window = NSWindow(contentViewController: viewController)
        let windowController = NSWindowController(window: window)
        window.delegate = self
        self.addWindowController(windowController)
    }

    override func read(from url: URL, ofType typeName: String) throws {
        sendLoadingStatus(true)
        let start = CFAbsoluteTimeGetCurrent()

        let semaphore = DispatchSemaphore(value: 0)
        let loadingResult = LoadResult()

        Task {
            let result: Result<ModelData, Swift.Error>
            do {
                result = .success(try await ModelData(url: url))
            } catch {
                result = .failure(error)
            }

            loadingResult.store(result)
            semaphore.signal()
        }

        while semaphore.wait(timeout: .now() + 0.01) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }

        guard let result = loadingResult.value else {
            sendLoadingStatus(false)
            throw Error.invalidDocument
        }

        do {
            sendModelData(try result.get())
        } catch {
            sendLoadingStatus(false)
            Swift.print("Error: \(error)")
            throw error
        }

        sendLoadingStatus(false)

        let end = CFAbsoluteTimeGetCurrent()
        Swift.print("Loading time: \(end - start)")
    }

    private func sendModelData(_ modelData: ModelData) {
        modelSubject.send(modelData)
    }

    private func sendLoadingStatus(_ isLoading: Bool) {
        loadingSubject.send(isLoading)
    }

    var documentHostingController: DocumentHostingController? {
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
           let viewOptions = try? JSONDecoder().decode(ViewOptions.self, from: data)
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
        let diskModificationDate = try? FileManager().attributesOfItem(atPath: fileURL.path(percentEncoded: false))[.modificationDate] as? Date
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

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        measurementUndoManager
    }
}

private final class LoadResult {
    private let queue = DispatchQueue(label: "se.tomasf.CadovaViewer.Document.LoadResult")
    private var result: Result<ModelData, Swift.Error>?

    var value: Result<ModelData, Swift.Error>? {
        queue.sync { result }
    }

    func store(_ result: Result<ModelData, Swift.Error>) {
        queue.sync {
            self.result = result
        }
    }
}

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
    private let modelSubject: CurrentValueSubject<ModelData?, Never> = .init(nil)
    private let loadingSubject: CurrentValueSubject<Bool, Never> = .init(false)
    /// Number of slice operations currently writing a filtered copy of the archive. A count (rather
    /// than a flag) so overlapping slices keep the indicator up until the last one finishes.
    private let slicingSubject: CurrentValueSubject<Int, Never> = .init(0)
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    var modelStream: AnyPublisher<ModelData, Never> {
        modelSubject.compactMap { $0 }.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    var loadingStream: AnyPublisher<Bool, Never> {
        loadingSubject.receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    var slicingStream: AnyPublisher<Bool, Never> {
        slicingSubject.map { $0 > 0 }.removeDuplicates().receive(on: DispatchQueue.main).eraseToAnyPublisher()
    }

    /// Dedicated undo manager for in-view interactions (measurements, cross-sections). Kept separate
    /// from the document's own `undoManager` so registering these undos doesn't mark the (read-only)
    /// document as edited. Vended to the window below so Edit ▸ Undo/Redo (⌘Z/⌘⇧Z) use it.
    let interactionUndoManager = UndoManager()

    override class func canConcurrentlyReadDocuments(ofType typeName: String) -> Bool {
        true
    }

    deinit {
        loadTask?.cancel()
    }

    override func makeWindowControllers() {
        let viewController = DocumentHostingController(document: self)
        let window = NSWindow(contentViewController: viewController)
        // Make SwiftUI's NavigationSplitView draw the modern full-height sidebar — its material runs
        // all the way up under the title bar. A pure SwiftUI WindowGroup configures this
        // automatically; a manually created AppKit window needs both the unified toolbar style and
        // `.fullSizeContentView` (so content, including the sidebar, extends into the title-bar area).
        window.toolbarStyle = .unified
        window.styleMask.insert(.fullSizeContentView)
        let windowController = NSWindowController(window: window)
        window.delegate = self
        self.addWindowController(windowController)
    }

    override func read(from url: URL, ofType typeName: String) throws {
        Task { @MainActor [weak self] in
            self?.startLoadingModel(from: url, fileModificationDate: nil, presentsZipErrors: true)
        }
    }

    private func sendModelData(_ modelData: ModelData) {
        modelSubject.send(modelData)
    }

    private func sendLoadingStatus(_ isLoading: Bool) {
        loadingSubject.send(isLoading)
    }

    @MainActor
    private func startLoadingModel(from url: URL, fileModificationDate: Date?, presentsZipErrors: Bool) {
        loadGeneration += 1
        let generation = loadGeneration
        loadTask?.cancel()
        sendLoadingStatus(true)

        let start = CFAbsoluteTimeGetCurrent()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let modelData = try await ModelData(url: url)
            try Task.checkCancellation()
            return modelData
        }

        loadTask = Task { [weak self] in
            let result: Result<ModelData, Swift.Error>

            do {
                let modelData = try await worker.value
                try Task.checkCancellation()
                result = .success(modelData)
            } catch is CancellationError {
                worker.cancel()
                return
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                self?.finishLoadingModel(
                    result,
                    generation: generation,
                    startTime: start,
                    fileModificationDate: fileModificationDate,
                    presentsZipErrors: presentsZipErrors
                )
            }
        }
    }

    @MainActor
    private func finishLoadingModel(_ result: Result<ModelData, Swift.Error>, generation: Int, startTime: CFAbsoluteTime, fileModificationDate: Date?, presentsZipErrors: Bool) {
        guard generation == loadGeneration else { return }

        defer {
            sendLoadingStatus(false)
            let end = CFAbsoluteTimeGetCurrent()
            Swift.print("Loading time: \(end - startTime)")
        }

        do {
            let modelData = try result.get()
            if let fileModificationDate {
                self.fileModificationDate = fileModificationDate
            }
            sendModelData(modelData)
        } catch(let error as ZipError) where !presentsZipErrors {
            Swift.print("Failed to auto-read archive: \(error)")
        } catch {
            Swift.print("Error: \(error)")
            presentError(error)
        }
    }

    /// Slices the given candidate `parts` of the model in the preferred slicer, keeping the slicing
    /// indicator up while the filtered copy is written. Pass all parts for a full slice, or the visible
    /// subset for "Slice Visible Parts". Routed through the document so every trigger (toolbar, parts
    /// list, context menu) shares the same in-progress state, and so the full item count — needed to
    /// decide whether any surgery is required — comes from the authoritative loaded model.
    func sliceModel(parts: [ModelData.Part]) {
        guard let fileURL, let totalItemCount = modelSubject.value?.parts.count else { return }
        do {
            guard let operation = try SlicingService.sliceModel(at: fileURL, parts: parts, totalItemCount: totalItemCount) else { return }
            run(operation)
        } catch {
            presentError(error)
        }
    }

    /// Slices a single part in the preferred slicer.
    func slicePart(_ part: ModelData.Part) {
        guard let fileURL, let operation = SlicingService.slicePart(part, at: fileURL) else { return }
        run(operation)
    }

    /// Runs a resolved slice, keeping the slicing indicator up for the duration of any archive write
    /// (operations that just hand the original file to the slicer show no indicator).
    private func run(_ operation: SlicingService.Operation) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if operation.showsProgress { beginSlicing() }
            defer { if operation.showsProgress { endSlicing() } }
            do {
                try await operation.run()
            } catch {
                presentError(error)
            }
        }
    }

    private func beginSlicing() { slicingSubject.value += 1 }
    private func endSlicing() { slicingSubject.value = max(0, slicingSubject.value - 1) }

    var documentHostingController: DocumentHostingController? {
        windowControllers.first?.contentViewController as? DocumentHostingController
    }

    private static let layoutStateKey = "documentLayoutState"

    override func encodeRestorableState(with coder: NSCoder) {
        super.encodeRestorableState(with: coder)
        guard let state = documentHostingController?.viewModel.snapshot(),
              let data = try? JSONEncoder().encode(state)
        else { return }

        coder.encode(data, forKey: Self.layoutStateKey)
    }

    override func restoreState(with coder: NSCoder) {
        super.restoreState(with: coder)
        if let data = coder.decodeObject(forKey: Self.layoutStateKey) as? Data,
           let state = try? JSONDecoder().decode(DocumentLayoutState.self, from: data)
        {
            documentHostingController?.viewModel.restore(state)
        }
    }

    override class func allowedClasses(forRestorableStateKeyPath keyPath: String) -> [AnyClass] {
        [NSData.self]
    }

    override func presentedItemDidChange() {
        super.presentedItemDidChange()

        guard let fileURL else { return }
        let diskModificationDate = try? FileManager().attributesOfItem(atPath: fileURL.path(percentEncoded: false))[.modificationDate] as? Date
        let lastKnownModificationDate = fileModificationDate

        guard let diskModificationDate, let lastKnownModificationDate, diskModificationDate > lastKnownModificationDate else {
            return // Item on disk was unchanged
        }

        Task { @MainActor [weak self] in
            self?.startLoadingModel(from: fileURL, fileModificationDate: diskModificationDate, presentsZipErrors: false)
        }
    }

    enum Error: Swift.Error {
        case invalidDocument
    }

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        proposedOptions.union(.autoHideToolbar)
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        interactionUndoManager
    }
}

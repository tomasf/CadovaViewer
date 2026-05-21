import Foundation
import Cocoa

final class PreviewListener: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private var openDocumentsByName: [String: WeakRef<Document>] = [:]
    private let lock = NSLock()

    override init() {
        listener = NSXPCListener(machServiceName: CadovaPreview.machServiceName)
        super.init()
        listener.delegate = self
    }

    func start() {
        listener.resume()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = CadovaPreview.xpcInterface
        connection.exportedObject = PreviewServiceImpl(owner: self)
        connection.resume()
        return true
    }

    @MainActor
    fileprivate func openOrReplaceDocument(named name: String, threeMFData data: Data) async throws {
        lock.lock()
        let existing = openDocumentsByName[name]?.value
        lock.unlock()

        if let existing, existing.windowControllers.isEmpty == false {
            try await existing.loadFrom(data: data, name: name)
            existing.showWindows()
            return
        }

        let doc = try NSDocumentController.shared.makeUntitledDocument(ofType: "org.3mf.threemfpackage") as! Document
        NSDocumentController.shared.addDocument(doc)
        doc.makeWindowControllers()
        doc.showWindows()
        try await doc.loadFrom(data: data, name: name)

        lock.lock()
        openDocumentsByName[name] = WeakRef(doc)
        lock.unlock()
    }
}

private final class WeakRef<T: AnyObject> {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

private final class PreviewServiceImpl: NSObject, CadovaPreviewService {
    private weak var owner: PreviewListener?

    init(owner: PreviewListener) {
        self.owner = owner
    }

    func openModel(named name: String,
                   threeMFData: Data,
                   reply: @escaping (Bool, String?) -> Void) {
        guard let owner else {
            reply(false, "Preview listener is gone")
            return
        }
        Task { @MainActor in
            do {
                try await owner.openOrReplaceDocument(named: name, threeMFData: threeMFData)
                reply(true, nil)
            } catch {
                reply(false, String(describing: error))
            }
        }
    }
}

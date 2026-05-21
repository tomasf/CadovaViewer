import Foundation
import Cocoa

final class PreviewListener: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    @MainActor private var openDocumentsByName: [String: WeakRef<Document>] = [:]

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
        openDocumentsByName = openDocumentsByName.filter { $0.value.value != nil }

        if let existing = openDocumentsByName[name]?.value, existing.windowControllers.isEmpty == false {
            try await existing.loadFrom(data: data, name: name)
            existing.showWindows()
            return
        }

        let doc = Document()
        NSDocumentController.shared.addDocument(doc)
        try await doc.loadFrom(data: data, name: name)
        doc.makeWindowControllers()
        doc.showWindows()
        openDocumentsByName[name] = WeakRef(doc)
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

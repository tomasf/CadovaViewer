import Cocoa
import ViewerCore

/// The app's `NSDocumentController`, subclassed only to hook `addDocument`/`removeDocument` — the
/// exact, documented points where a document enters or leaves `documents` (unlike
/// `NSDocumentController.documents` itself, which isn't documented as KVO-compliant, or a
/// `Document`-level hook like `makeWindowControllers()`/`close()`, whose timing relative to
/// `documents` actually updating isn't guaranteed). Used to keep the LiveLink host-state file
/// (`LiveLinkService.updateOpenDocuments`) in sync with which documents are actually open, so a
/// sender can tell whether it's worth pushing without connecting to ask.
///
/// Must be instantiated before the app opens any document — see `AppDelegate.documentController`.
final class DocumentController: NSDocumentController {
    override init() {
        super.init()
        // Writes the state file immediately at launch (normally with an empty path list, since no
        // document has opened yet) rather than leaving it to the first addDocument/removeDocument.
        // Without this, a stale file from a previous run that crashed without reaching `stop()`
        // could sit there — with a dead PID and paths nobody's watching anymore — until this launch
        // happens to open or close a document.
        refreshLiveLinkOpenDocuments()
    }

    // Only the programmatic init() above is ever actually used (see the type comment) — this app
    // has no nib/storyboard that instantiates a document controller — but overriding a designated
    // initializer means Swift requires this required initializer to be satisfied too.
    required init?(coder: NSCoder) {
        fatalError("DocumentController does not support NSCoding")
    }

    override func addDocument(_ document: NSDocument) {
        super.addDocument(document)
        refreshLiveLinkOpenDocuments()
    }

    override func removeDocument(_ document: NSDocument) {
        super.removeDocument(document)
        refreshLiveLinkOpenDocuments()
    }

    private func refreshLiveLinkOpenDocuments() {
        let paths = documents.compactMap { ($0 as? Document)?.fileURL?.path(percentEncoded: false) }
        LiveLinkService.shared.updateOpenDocuments(paths: paths)
    }
}

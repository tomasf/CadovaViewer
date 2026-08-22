import Cocoa
import SwiftUI
import ViewerCore

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var preferencesWindow: NSWindow?

    // Declared first so its default-value initializer runs before any other property's (Swift
    // evaluates these in declaration order) — must complete before anything reads
    // Preferences()/UserDefaults.standard, which the first document window's ViewportController
    // already does, possibly as early as Launch Services handing this process a file to open.
    private let preferencesMigrationRun: Void = PreferencesMigration.runIfNeeded()

    // Created here so it exists before AppKit's run loop starts and can process any "open untitled
    // document" or Launch Services file-open request — NSDocumentController.shared lazily creates a
    // plain NSDocumentController the first time anything asks for one, and that first instance can't
    // be swapped out afterward.
    private let documentController = DocumentController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        LiveLinkService.shared.hasOpenDocument = { url in
            NSDocumentController.shared.document(for: url) is Document
        }
        LiveLinkService.shared.onLoadingStarted = { url in
            guard let document = NSDocumentController.shared.document(for: url) as? Document else { return }
            document.beginLiveLinkLoad()
        }
        LiveLinkService.shared.onModelUpdate = { url, modelData, buildUUID in
            guard let document = NSDocumentController.shared.document(for: url) as? Document else { return }
            document.applyLiveLinkUpdate(modelData: modelData, buildUUID: buildUUID)
        }
        LiveLinkService.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        LiveLinkService.shared.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            NSDocumentController.shared.openDocument(nil)
            return false
        } else {
            return true
        }
    }

    @IBAction
    func showPreferences(_ sender: AnyObject) {
        if preferencesWindow == nil {
            preferencesWindow = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView()))
            preferencesWindow?.contentMinSize = NSSize(width: 650, height: 420)
            preferencesWindow?.setFrameAutosaveName("preferences")
            preferencesWindow?.title = "Settings"
        }

        preferencesWindow?.makeKeyAndOrderFront(nil)
    }
}

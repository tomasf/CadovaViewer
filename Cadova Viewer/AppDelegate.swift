import Cocoa
import SwiftUI
import ViewerCore

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var preferencesWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LiveLinkService.shared.onModelUpdate = { url, modelData, token in
            guard let document = NSDocumentController.shared.document(for: url) as? Document else { return }
            document.applyLiveLinkUpdate(modelData: modelData, token: token)
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

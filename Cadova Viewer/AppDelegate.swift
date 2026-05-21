import Cocoa
import SwiftUI

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var preferencesWindow: NSWindow?
    private var previewListener: PreviewListener?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let listener = PreviewListener()
        listener.start()
        previewListener = listener
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
            preferencesWindow?.setFrameAutosaveName("preferences")
            preferencesWindow?.title = "Settings"
        }

        preferencesWindow?.makeKeyAndOrderFront(nil)
    }
}

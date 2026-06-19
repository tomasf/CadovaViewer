import Cocoa
import SwiftUI

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var preferencesWindow: NSWindow?

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

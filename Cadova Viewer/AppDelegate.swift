import Cocoa
import SwiftUI

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    var preferencesWindow: NSWindow?

    @IBAction func printResponderChain(_ sender: Any?) {
        var responder: NSResponder? = NSApp.keyWindow?.firstResponder

        while true {
            guard let localResponder = responder else { return }
            print("Responder: \(localResponder)")
            responder = localResponder.nextResponder
        }
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
            preferencesWindow?.title = "Preferences"
        }

        preferencesWindow?.makeKeyAndOrderFront(nil)
    }
}

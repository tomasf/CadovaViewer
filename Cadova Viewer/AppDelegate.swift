import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {
    @IBAction func printResponderChain(_ sender: Any?) {
        var responder: NSResponder? = NSApp.keyWindow?.firstResponder

        while true {
            guard let localResponder = responder else { return }
            print("Responder: \(localResponder)")
            responder = localResponder.nextResponder
        }
    }
}


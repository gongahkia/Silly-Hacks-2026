import AppKit
import AngyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: AngyController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = AngyController(config: .live)
        controller?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.stop()
    }
}

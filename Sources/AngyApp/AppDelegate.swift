import AppKit
import AngyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AngyHiveCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = AngyHiveCoordinator(config: .live)
        coordinator?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}

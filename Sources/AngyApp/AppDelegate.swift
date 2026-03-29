import AppKit
import AngyCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: AngyHiveCoordinator?
    private let launchOptions = AngyLaunchOptions.current()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = AngyHiveCoordinator(
            config: .live,
            launchOptions: launchOptions
        )
        coordinator?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }
}

import AngyCore
import Foundation

@MainActor
protocol TrackedWindowSource: AnyObject {
    var onWindowChange: (() -> Void)? { get set }

    func startMonitoring()
    func stopMonitoring()
    func currentTrackedWindow() async -> TrackedWindow?
}

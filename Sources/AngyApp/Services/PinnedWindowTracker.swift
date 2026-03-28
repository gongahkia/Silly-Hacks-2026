import AngyCore
import Foundation

@MainActor
final class PinnedWindowTracker: TrackedWindowSource {
    private let windowID: UInt32
    private let refreshInterval: TimeInterval
    private let catalogService = WindowCatalogService()
    private var timer: Timer?
    private var lastWindow: TrackedWindow?

    var onWindowChange: (() -> Void)?

    init(windowID: UInt32, refreshInterval: TimeInterval) {
        self.windowID = windowID
        self.refreshInterval = refreshInterval
    }

    func startMonitoring() {
        guard timer == nil else {
            return
        }

        let timer = Timer.scheduledTimer(
            timeInterval: refreshInterval,
            target: self,
            selector: #selector(handleTimerTick),
            userInfo: nil,
            repeats: true
        )
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        handleTimerTick()
    }

    func stopMonitoring() {
        timer?.invalidate()
        timer = nil
        lastWindow = nil
    }

    func currentTrackedWindow() async -> TrackedWindow? {
        catalogService.window(windowID: windowID)
    }

    @objc
    private func handleTimerTick() {
        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            let nextWindow = await currentTrackedWindow()
            guard nextWindow != lastWindow else {
                return
            }

            lastWindow = nextWindow
            onWindowChange?()
        }
    }
}

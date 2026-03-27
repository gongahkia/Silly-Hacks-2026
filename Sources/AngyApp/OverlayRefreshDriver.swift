import CoreVideo
import Foundation

final class OverlayRefreshDriver: NSObject {
    private let fallbackInterval: TimeInterval
    private let onTick: @MainActor () -> Void
    private let stateLock = NSLock()

    private var displayLink: CVDisplayLink?
    @MainActor private var fallbackTimer: Timer?

    private var isRunning = false
    private var tickPending = false

    init(
        fallbackInterval: TimeInterval,
        onTick: @escaping @MainActor () -> Void
    ) {
        self.fallbackInterval = fallbackInterval
        self.onTick = onTick
        super.init()
    }

    deinit {
        stopDisplayLinkIfNeeded()
    }

    @MainActor
    func start() {
        let shouldStart = stateLock.withLock { () -> Bool in
            guard !isRunning else {
                return false
            }

            isRunning = true
            return true
        }

        guard shouldStart else {
            return
        }

        guard startDisplayLinkIfNeeded() else {
            startFallbackTimer()
            return
        }

        stopFallbackTimer()
    }

    @MainActor
    func stop() {
        let shouldStop = stateLock.withLock { () -> Bool in
            guard isRunning else {
                return false
            }

            isRunning = false
            tickPending = false
            return true
        }

        guard shouldStop else {
            return
        }

        stopFallbackTimer()
        stopDisplayLinkIfNeeded()
    }

    private func startDisplayLinkIfNeeded() -> Bool {
        if let displayLink {
            let result = CVDisplayLinkStart(displayLink)
            return result == kCVReturnSuccess || result == kCVReturnDisplayLinkAlreadyRunning
        }

        var newDisplayLink: CVDisplayLink?
        let creationResult = CVDisplayLinkCreateWithActiveCGDisplays(&newDisplayLink)
        guard creationResult == kCVReturnSuccess, let newDisplayLink else {
            return false
        }

        let callbackResult = CVDisplayLinkSetOutputCallback(
            newDisplayLink,
            Self.displayLinkOutputCallback,
            Unmanaged.passUnretained(self).toOpaque()
        )

        guard callbackResult == kCVReturnSuccess else {
            return false
        }

        displayLink = newDisplayLink
        let startResult = CVDisplayLinkStart(newDisplayLink)
        return startResult == kCVReturnSuccess || startResult == kCVReturnDisplayLinkAlreadyRunning
    }

    private func stopDisplayLinkIfNeeded() {
        guard let displayLink else {
            return
        }

        if CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStop(displayLink)
        }
    }

    @MainActor
    private func startFallbackTimer() {
        guard fallbackTimer == nil else {
            return
        }

        let timer = Timer.scheduledTimer(
            timeInterval: fallbackInterval,
            target: self,
            selector: #selector(handleFallbackTimerTick),
            userInfo: nil,
            repeats: true
        )

        fallbackTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @MainActor
    private func stopFallbackTimer() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    private func scheduleTick() {
        let shouldSchedule = stateLock.withLock { () -> Bool in
            guard isRunning, !tickPending else {
                return false
            }

            tickPending = true
            return true
        }

        guard shouldSchedule else {
            return
        }

        Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            defer {
                self.stateLock.withLock {
                    self.tickPending = false
                }
            }

            let isRunning = self.stateLock.withLock { self.isRunning }
            guard isRunning else {
                return
            }

            self.onTick()
        }
    }

    private static let displayLinkOutputCallback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo in
        guard let userInfo else {
            return kCVReturnError
        }

        let driver = Unmanaged<OverlayRefreshDriver>.fromOpaque(userInfo).takeUnretainedValue()
        driver.scheduleTick()
        return kCVReturnSuccess
    }

    @objc
    private func handleFallbackTimerTick() {
        scheduleTick()
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

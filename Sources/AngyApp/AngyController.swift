import AppKit
import AngyCore
import Foundation

@MainActor
final class AngyController: NSObject {
    private let config: AppConfig
    private let permissionManager = PermissionManager()
    private let windowTracker: WindowTracker
    private let analysisWorker = SessionAnalysisWorker()
    private let overlayController: CompanionOverlayController
    private let sentimentEngine: SentimentEngine
    private let textBuffer: RollingTextBuffer
    private let debugMonitor = DebugMonitor.shared

    private lazy var overlayRefreshDriver = OverlayRefreshDriver(
        fallbackInterval: config.overlayRefreshInterval
    ) { [weak self] in
        self?.handleDisplayLinkedOverlayTick()
    }
    private var analysisTimer: Timer?
    private var analysisTask: Task<Void, Never>?
    private var stickerWarmupTask: Task<Void, Never>?
    private var windowRefreshTask: Task<Void, Never>?
    private var windowRefreshQueued = false
    private var trackedWindow: TrackedWindow?
    private var permissionOnboardingShown = false
    private var angerScore = 0.0
    private var companionState: CompanionState = .calm
    private var activeQuip: String?
    private var activeStickerName: String?
    private var lastQuipDate: Date?
    private var nextStickerChangeDate: Date?

    init(config: AppConfig) {
        self.config = config
        self.windowTracker = WindowTracker(config: config)
        self.overlayController = CompanionOverlayController(config: config)
        self.sentimentEngine = SentimentEngine(config: config)
        self.textBuffer = RollingTextBuffer(windowDuration: config.rollingWindowDuration)
        super.init()
    }

    func start() {
        debugMonitor.announceIfEnabled()
        windowTracker.onWindowChange = { [weak self] in
            self?.scheduleWindowRefresh()
        }
        windowTracker.startMonitoring()
        scheduleStickerWarmup()
        promptForPermissionsIfNeeded()
        scheduleWindowRefresh()
        scheduleAnalysis()
        updateOverlayRefreshDriver()

        analysisTimer = Timer.scheduledTimer(
            timeInterval: config.textRefreshInterval,
            target: self,
            selector: #selector(handleAnalysisTick),
            userInfo: nil,
            repeats: true
        )

        if let analysisTimer {
            RunLoop.main.add(analysisTimer, forMode: .common)
        }
    }

    func stop() {
        overlayRefreshDriver.stop()
        analysisTimer?.invalidate()
        analysisTimer = nil
        analysisTask?.cancel()
        analysisTask = nil
        stickerWarmupTask?.cancel()
        stickerWarmupTask = nil
        windowRefreshTask?.cancel()
        windowRefreshTask = nil
        windowRefreshQueued = false
        windowTracker.onWindowChange = nil
        windowTracker.stopMonitoring()
    }

    private func handleDisplayLinkedOverlayTick() {
        scheduleWindowRefresh()
    }

    @objc
    private func handleAnalysisTick() {
        scheduleAnalysis()
    }

    private func scheduleWindowRefresh() {
        windowRefreshQueued = true

        guard windowRefreshTask == nil else {
            return
        }

        windowRefreshTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            repeat {
                self.windowRefreshQueued = false
                let trackedWindow = await self.windowTracker.currentTrackedWindow()

                guard !Task.isCancelled else {
                    break
                }

                self.applyTrackedWindow(trackedWindow)
            } while self.windowRefreshQueued && !Task.isCancelled

            self.windowRefreshTask = nil

            if self.windowRefreshQueued && !Task.isCancelled {
                self.scheduleWindowRefresh()
            }
        }
    }

    private func applyTrackedWindow(_ nextTrackedWindow: TrackedWindow?) {
        let previousWindowTarget = trackedWindow.map(AnalysisTarget.init)

        if let window = nextTrackedWindow {
            trackedWindow = window
            overlayController.present(
                window: window,
                state: companionState,
                stickerName: activeStickerName ?? CompanionPersona.defaultSticker(for: companionState),
                quip: activeQuip
            )
        } else {
            trackedWindow = nil
            overlayController.hide()
        }

        let currentWindowTarget = trackedWindow.map(AnalysisTarget.init)
        if previousWindowTarget != currentWindowTarget {
            analysisTask?.cancel()
            analysisTask = nil
            if currentWindowTarget != nil {
                scheduleAnalysis()
            }
        }

        updateOverlayRefreshDriver()
        debugMonitor.recordOverlay(window: trackedWindow, state: companionState)
    }

    private func scheduleAnalysis() {
        promptForPermissionsIfNeeded()

        guard let window = trackedWindow else {
            let result = sentimentEngine.analyze(
                observations: [],
                previousAngerScore: angerScore,
                previousState: companionState
            )
            angerScore = result.finalAngerScore
            companionState = result.currentState
            activeQuip = nil
            return
        }

        guard analysisTask == nil else {
            return
        }

        let permissions = permissionManager.status()
        let analysisTarget = AnalysisTarget(window)
        let minimumMeaningfulTextLength = config.minimumMeaningfulTextLength

        analysisTask = Task { [weak self] in
            guard let self else {
                return
            }

            let extraction = await analysisWorker.extractObservation(
                for: window,
                permissions: permissions,
                minimumMeaningfulTextLength: minimumMeaningfulTextLength
            )

            guard !Task.isCancelled else {
                await MainActor.run {
                    self.analysisTask = nil
                }
                return
            }

            await MainActor.run {
                defer {
                    self.analysisTask = nil
                }

                guard self.trackedWindow.map(AnalysisTarget.init) == analysisTarget else {
                    return
                }

                self.applyAnalysis(extraction, to: window)
            }
        }
    }

    private func applyAnalysis(
        _ extraction: SessionObservationExtraction,
        to window: TrackedWindow
    ) {
        if let observation = extraction.observation {
            textBuffer.append(observation, now: observation.timestamp)
        } else {
            textBuffer.prune()
        }

        let previousState = companionState
        let result = sentimentEngine.analyze(
            observations: textBuffer.observations,
            previousAngerScore: angerScore,
            previousState: companionState
        )

        angerScore = result.finalAngerScore
        companionState = result.currentState
        updateStickerIfNeeded(
            matchedTriggers: result.matchedTriggers,
            previousState: previousState,
            currentState: result.currentState
        )
        activeQuip = nextQuip(
            matchedTriggers: result.matchedTriggers,
            previousState: previousState,
            currentState: result.currentState
        )

        debugMonitor.recordAnalysis(
            extraction: extraction.reason,
            observation: extraction.observation,
            angerScore: angerScore,
            state: companionState,
            stickerName: activeStickerName,
            triggers: result.matchedTriggers,
            quip: activeQuip
        )

        overlayController.present(
            window: window,
            state: companionState,
            stickerName: activeStickerName ?? CompanionPersona.defaultSticker(for: companionState),
            quip: activeQuip
        )
    }

    private func promptForPermissionsIfNeeded() {
        guard !permissionOnboardingShown else { return }
        let status = permissionManager.status()
        guard !status.accessibility || !status.screenRecording else { return }

        permissionOnboardingShown = true
        permissionManager.requestMissingPermissions()
        permissionManager.presentOnboardingIfNeeded()
    }

    private func nextQuip(
        matchedTriggers: [String],
        previousState: CompanionState,
        currentState: CompanionState
    ) -> String? {
        let now = Date()

        if currentState == .calm, angerScore < 15 {
            lastQuipDate = nil
            return nil
        }

        let cooledDown = lastQuipDate.map { now.timeIntervalSince($0) >= config.quipCooldown } ?? true
        let stateChanged = previousState != currentState
        let sustainedHighAnger = angerScore >= 65

        guard stateChanged || (sustainedHighAnger && cooledDown) else {
            return activeQuip
        }

        lastQuipDate = now
        return CompanionPersona.quip(for: currentState, triggers: matchedTriggers)
    }

    private func updateStickerIfNeeded(
        matchedTriggers: [String],
        previousState: CompanionState,
        currentState: CompanionState
    ) {
        let now = Date()
        let stateChanged = previousState != currentState
        let canRotateSticker = nextStickerChangeDate.map { now >= $0 } ?? true

        guard activeStickerName == nil || stateChanged || canRotateSticker else {
            return
        }

        activeStickerName = CompanionPersona.stickerName(
            for: currentState,
            triggers: matchedTriggers,
            previousStickerName: activeStickerName
        )
        nextStickerChangeDate = now.addingTimeInterval(
            Double.random(in: config.stickerHoldMinimum...config.stickerHoldMaximum)
        )
    }

    private func scheduleStickerWarmup() {
        stickerWarmupTask?.cancel()

        let stickerNames = startupStickerNames()
        guard !stickerNames.isEmpty else {
            return
        }

        let assetSources = stickerNames.compactMap(CompanionPersona.assetSource(for:))

        stickerWarmupTask = Task(priority: .utility) {
            for assetSource in assetSources {
                guard !Task.isCancelled else {
                    return
                }

                _ = await ASCIIStickerRenderer.shared.renderSequence(from: assetSource)
            }
        }
    }

    private func startupStickerNames() -> [String] {
        let names = ["default"] + CompanionState.allCases.map { CompanionPersona.defaultSticker(for: $0) }
        var ordered: [String] = []
        var seen = Set<String>()

        for name in names where seen.insert(name).inserted {
            ordered.append(name)
        }

        return ordered
    }

    private func updateOverlayRefreshDriver() {
        if shouldRunDisplayLinkedRefresh {
            overlayRefreshDriver.start()
        } else {
            overlayRefreshDriver.stop()
        }
    }

    private var shouldRunDisplayLinkedRefresh: Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }

        return config.targetBundleIDs.contains(bundleID)
    }
}

private struct AnalysisTarget: Equatable {
    let bundleID: String
    let windowID: UInt32

    init(_ window: TrackedWindow) {
        bundleID = window.bundleID
        windowID = window.windowID
    }
}

private struct SessionObservationExtraction: Sendable {
    let observation: TextObservation?
    let reason: String
}

private actor SessionAnalysisWorker {
    private let accessibilityExtractor = AccessibilityTextExtractor()
    private let ocrService = WindowOCRService()

    func extractObservation(
        for window: TrackedWindow,
        permissions: PermissionStatus,
        minimumMeaningfulTextLength: Int
    ) -> SessionObservationExtraction {
        if Task.isCancelled {
            return SessionObservationExtraction(observation: nil, reason: "cancelled")
        }

        let now = Date()

        if permissions.accessibility,
           let rawText = accessibilityExtractor.extractText(
                forBundleIdentifier: window.bundleID,
                appName: window.appName
           ),
           rawText.count >= minimumMeaningfulTextLength {
            return SessionObservationExtraction(
                observation: TextObservation(
                    timestamp: now,
                    source: .accessibility,
                    rawText: rawText,
                    normalizedText: TextNormalizer.normalize(rawText),
                    confidence: 1.0
                ),
                reason: "accessibility"
            )
        }

        if Task.isCancelled {
            return SessionObservationExtraction(observation: nil, reason: "cancelled")
        }

        if permissions.screenRecording,
           let ocrObservation = ocrService.extractText(for: window) {
            return SessionObservationExtraction(observation: ocrObservation, reason: "ocr")
        }

        var reasons: [String] = []

        if !permissions.accessibility {
            reasons.append("accessibility_denied")
        } else {
            reasons.append("accessibility_empty_or_short")
        }

        if !permissions.screenRecording {
            reasons.append("screen_recording_denied")
        } else {
            reasons.append("ocr_empty")
        }

        return SessionObservationExtraction(
            observation: nil,
            reason: reasons.joined(separator: "+")
        )
    }
}

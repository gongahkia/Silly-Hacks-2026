import AppKit
import AngyCore
import Foundation

@MainActor
final class AngyController: NSObject {
    private let config: AppConfig
    private let permissionManager = PermissionManager()
    private let windowTracker: WindowTracker
    private let accessibilityExtractor = AccessibilityTextExtractor()
    private let ocrService = WindowOCRService()
    private let overlayController: CompanionOverlayController
    private let sentimentEngine: SentimentEngine
    private let textBuffer: RollingTextBuffer
    private let debugMonitor = DebugMonitor.shared

    private var overlayTimer: Timer?
    private var analysisTimer: Timer?
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
        promptForPermissionsIfNeeded()
        refreshWindowContext()
        analyzeSession()

        overlayTimer = Timer.scheduledTimer(
            timeInterval: config.overlayRefreshInterval,
            target: self,
            selector: #selector(handleOverlayTick),
            userInfo: nil,
            repeats: true
        )

        analysisTimer = Timer.scheduledTimer(
            timeInterval: config.textRefreshInterval,
            target: self,
            selector: #selector(handleAnalysisTick),
            userInfo: nil,
            repeats: true
        )

        if let overlayTimer {
            RunLoop.main.add(overlayTimer, forMode: .common)
        }

        if let analysisTimer {
            RunLoop.main.add(analysisTimer, forMode: .common)
        }
    }

    func stop() {
        overlayTimer?.invalidate()
        overlayTimer = nil
        analysisTimer?.invalidate()
        analysisTimer = nil
    }

    @objc
    private func handleOverlayTick() {
        refreshWindowContext()
    }

    @objc
    private func handleAnalysisTick() {
        analyzeSession()
    }

    private func refreshWindowContext() {
        if let window = windowTracker.currentTrackedWindow() {
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

        debugMonitor.recordOverlay(window: trackedWindow, state: companionState)
    }

    private func analyzeSession() {
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

        let permissions = permissionManager.status()
        let extraction = extractObservation(for: window, permissions: permissions)

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

    private func extractObservation(
        for window: TrackedWindow,
        permissions: PermissionStatus
    ) -> (observation: TextObservation?, reason: String) {
        let now = Date()

        if permissions.accessibility,
           let rawText = accessibilityExtractor.extractText(
                forBundleIdentifier: window.bundleID,
                appName: window.appName
           ) {
            if rawText.count >= config.minimumMeaningfulTextLength {
                return (
                    TextObservation(
                        timestamp: now,
                        source: .accessibility,
                        rawText: rawText,
                        normalizedText: TextNormalizer.normalize(rawText),
                        confidence: 1.0
                    ),
                    "accessibility"
                )
            }
        }

        if permissions.screenRecording,
           let ocrObservation = ocrService.extractText(for: window) {
            return (ocrObservation, "ocr")
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

        return (nil, reasons.joined(separator: "+"))
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
}

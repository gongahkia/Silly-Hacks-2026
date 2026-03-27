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

    private var overlayTimer: Timer?
    private var analysisTimer: Timer?
    private var trackedWindow: TrackedWindow?
    private var permissionOnboardingShown = false
    private var angerScore = 0.0
    private var companionState: CompanionState = .calm
    private var activeQuip: String?
    private var lastQuipDate: Date?

    init(config: AppConfig) {
        self.config = config
        self.windowTracker = WindowTracker(config: config)
        self.overlayController = CompanionOverlayController(config: config)
        self.sentimentEngine = SentimentEngine(config: config)
        self.textBuffer = RollingTextBuffer(windowDuration: config.rollingWindowDuration)
        super.init()
    }

    func start() {
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
            overlayController.present(window: window, state: companionState, quip: activeQuip)
        } else {
            trackedWindow = nil
            overlayController.hide()
        }
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

        if let observation = extractObservation(for: window, permissions: permissions) {
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
        activeQuip = nextQuip(
            matchedTriggers: result.matchedTriggers,
            previousState: previousState,
            currentState: result.currentState
        )

        overlayController.present(window: window, state: companionState, quip: activeQuip)
    }

    private func extractObservation(
        for window: TrackedWindow,
        permissions: PermissionStatus
    ) -> TextObservation? {
        let now = Date()

        if permissions.accessibility,
           let rawText = accessibilityExtractor.extractText(
                forBundleIdentifier: window.bundleID,
                appName: window.appName
           ),
           rawText.count >= config.minimumMeaningfulTextLength {
            return TextObservation(
                timestamp: now,
                source: .accessibility,
                rawText: rawText,
                normalizedText: TextNormalizer.normalize(rawText),
                confidence: 1.0
            )
        }

        if permissions.screenRecording,
           let ocrObservation = ocrService.extractText(for: window) {
            return ocrObservation
        }

        return nil
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
}

import AppKit
import AngyCore
import Foundation

@MainActor
final class AngyInstanceController: NSObject {
    let id: AngyInstanceID
    let role: AngyInstanceRole

    private let config: AppConfig
    private let permissionManager = PermissionManager()
    private let analysisWorker: SessionAnalysisWorker
    private let activityClassifier = SessionActivityClassifier()
    private let overlayController: CompanionOverlayController
    private let soundEffectPlayer: SoundEffectPlayer
    private let sentimentEngine: SentimentEngine
    private let textBuffer: RollingTextBuffer
    private let debugMonitor = DebugMonitor.shared
    private let textIngestionMode: TextIngestionMode
    private let managesPermissions: Bool
    private let warmStickersOnStart: Bool
    private let allowsDisplayLinkedRefresh: Bool
    private let autoRemoveWhenTargetLost: Bool
    private let explosionAnimationDuration: TimeInterval = 0.6

    private var trackingSource: any TrackedWindowSource
    private var analysisTimer: Timer?
    private var analysisTask: Task<Void, Never>?
    private var effectTask: Task<Void, Never>?
    private var stickerWarmupTask: Task<Void, Never>?
    private var windowRefreshTask: Task<Void, Never>?
    private var windowRefreshQueued = false
    private var trackedWindow: TrackedWindow?
    private var permissionOnboardingShown = false
    private var angerScore = 0.0
    private var companionState: CompanionState = .calm
    private var activityState: SessionActivityState = .default
    private var overlayEffectPhase: OverlayEffectPhase = .alive
    private var activeQuip: String?
    private var activeStickerName: String?
    private var lastQuipDate: Date?
    private var nextStickerChangeDate: Date?
    private var explosionMonitor: ExplosionMonitor
    private var presentationState: OverlayPresentationState
    private var isPaused = false
    private var displayTag: String?
    private var overrideState: CompanionState?
    private var lastMatchedTriggers: [String] = []
    private var isStarted = false

    lazy var overlayRefreshDriver = OverlayRefreshDriver(
        fallbackInterval: config.overlayRefreshInterval
    ) { [weak self] in
        self?.handleDisplayLinkedOverlayTick()
    }

    var onSnapshotChange: ((AngyInstanceSnapshot) -> Void)?
    var onExplosion: ((AngyInstanceSnapshot) -> Void)?
    var onTargetLost: ((AngyInstanceID) -> Void)?

    init(
        id: AngyInstanceID,
        role: AngyInstanceRole,
        config: AppConfig,
        textIngestionMode: TextIngestionMode,
        codexHomeDirectory: URL,
        trackingSource: any TrackedWindowSource,
        managesPermissions: Bool,
        warmStickersOnStart: Bool,
        allowsDisplayLinkedRefresh: Bool,
        autoRemoveWhenTargetLost: Bool
    ) {
        let defaultSticker = CompanionPersona.defaultSticker(for: .calm, activity: .default)
        self.id = id
        self.role = role
        self.config = config
        self.textIngestionMode = textIngestionMode
        self.trackingSource = trackingSource
        self.managesPermissions = managesPermissions
        self.warmStickersOnStart = warmStickersOnStart
        self.allowsDisplayLinkedRefresh = allowsDisplayLinkedRefresh
        self.autoRemoveWhenTargetLost = autoRemoveWhenTargetLost
        self.analysisWorker = SessionAnalysisWorker(
            textIngestionMode: textIngestionMode,
            codexRolloutSource: textIngestionMode == .legacyScreenCapture
                ? nil
                : CodexRolloutTextSource(codexHomeDirectory: codexHomeDirectory)
        )
        self.overlayController = CompanionOverlayController(config: config)
        self.soundEffectPlayer = SoundEffectPlayer(config: config)
        self.sentimentEngine = SentimentEngine(config: config)
        self.textBuffer = RollingTextBuffer(windowDuration: config.rollingWindowDuration)
        self.explosionMonitor = ExplosionMonitor(config: config)
        self.activeStickerName = defaultSticker
        self.presentationState = .calmDefault(stickerName: defaultSticker)
        super.init()
    }

    func start() {
        guard !isStarted else {
            return
        }

        isStarted = true
        trackingSource.onWindowChange = { [weak self] in
            self?.scheduleWindowRefresh()
        }
        trackingSource.startMonitoring()

        if warmStickersOnStart {
            scheduleStickerWarmup()
        }

        if managesPermissions, textIngestionMode == .legacyScreenCapture {
            promptForPermissionsIfNeeded()
        }

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

        notifySnapshotChanged()
    }

    func stop() {
        overlayRefreshDriver.stop()
        analysisTimer?.invalidate()
        analysisTimer = nil
        analysisTask?.cancel()
        analysisTask = nil
        effectTask?.cancel()
        effectTask = nil
        stickerWarmupTask?.cancel()
        stickerWarmupTask = nil
        windowRefreshTask?.cancel()
        windowRefreshTask = nil
        windowRefreshQueued = false
        trackingSource.onWindowChange = nil
        trackingSource.stopMonitoring()
        overlayController.hide()
        isStarted = false
    }

    func setTrackingSource(_ trackingSource: any TrackedWindowSource) {
        let wasStarted = isStarted
        if wasStarted {
            self.trackingSource.onWindowChange = nil
            self.trackingSource.stopMonitoring()
        }

        self.trackingSource = trackingSource

        if wasStarted {
            self.trackingSource.onWindowChange = { [weak self] in
                self?.scheduleWindowRefresh()
            }
            self.trackingSource.startMonitoring()
            scheduleWindowRefresh()
        }
    }

    func setDisplayTag(_ tag: String?) {
        guard displayTag != tag else {
            return
        }

        displayTag = tag
        rebuildPresentationState()
        presentCurrentState()
        notifySnapshotChanged()
    }

    func pause() {
        guard !isPaused else {
            return
        }

        isPaused = true
        analysisTask?.cancel()
        analysisTask = nil
        activeQuip = nil
        rebuildPresentationState()
        presentCurrentState()
        notifySnapshotChanged()
    }

    func resume() {
        guard isPaused else {
            return
        }

        isPaused = false
        scheduleAnalysis()
        notifySnapshotChanged()
    }

    func setOverrideState(_ state: CompanionState) {
        overrideState = state
        rebuildPresentationState()
        presentCurrentState()
        notifySnapshotChanged()
    }

    func clearOverrideState() {
        guard overrideState != nil else {
            return
        }

        overrideState = nil
        rebuildPresentationState()
        presentCurrentState()
        notifySnapshotChanged()
    }

    @discardableResult
    func forceExplosion() -> Bool {
        guard overlayEffectPhase == .alive, let trackedWindow else {
            return false
        }

        let previousPresentation = presentationState
        companionState = .furious
        angerScore = max(angerScore, config.explosionThreshold)
        return triggerExplosion(
            window: trackedWindow,
            previousPresentation: previousPresentation,
            force: true
        )
    }

    func snapshot() -> AngyInstanceSnapshot {
        AngyInstanceSnapshot(
            id: id,
            role: role,
            tag: displayTag,
            target: trackedWindow.map(AngyWindowRef.init(window:)),
            emotion: effectiveCompanionState,
            activity: activityState,
            angerScore: angerScore,
            paused: isPaused,
            effectPhase: overlayEffectPhase.rawValue,
            quip: overlayEffectPhase == .alive ? activeQuip : nil,
            matchedTriggers: lastMatchedTriggers
        )
    }

    private var effectiveCompanionState: CompanionState {
        overrideState ?? companionState
    }

    private func notifySnapshotChanged() {
        onSnapshotChange?(snapshot())
    }

    private func presentCurrentState() {
        if let trackedWindow {
            overlayController.present(window: trackedWindow, presentation: presentationState)
        } else {
            overlayController.hide()
        }
    }

    private func handleDisplayLinkedOverlayTick() {
        scheduleWindowRefresh()
    }

    @objc
    private func handleAnalysisTick() {
        guard !isPaused else {
            return
        }

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
                let trackedWindow = await self.trackingSource.currentTrackedWindow()

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
            overlayController.present(window: window, presentation: presentationState)
        } else {
            trackedWindow = nil
            overlayController.hide()
        }

        if autoRemoveWhenTargetLost,
           previousWindowTarget != nil,
           nextTrackedWindow == nil {
            onTargetLost?(id)
        }

        let currentWindowTarget = trackedWindow.map(AnalysisTarget.init)
        if previousWindowTarget != currentWindowTarget {
            analysisTask?.cancel()
            analysisTask = nil
            if currentWindowTarget != nil, !isPaused {
                scheduleAnalysis()
            }
        }

        updateOverlayRefreshDriver()
        debugMonitor.recordOverlay(window: trackedWindow, state: effectiveCompanionState)
        notifySnapshotChanged()
    }

    private func scheduleAnalysis() {
        if managesPermissions, textIngestionMode == .legacyScreenCapture {
            promptForPermissionsIfNeeded()
        }

        guard !isPaused else {
            return
        }

        guard let window = trackedWindow else {
            if overlayEffectPhase == .alive {
                let result = sentimentEngine.analyze(
                    observations: [],
                    previousAngerScore: angerScore,
                    previousState: companionState
                )
                angerScore = result.finalAngerScore
                companionState = result.currentState
                activityState = .default
                activeQuip = nil
                lastMatchedTriggers = []
                rebuildPresentationState()
                notifySnapshotChanged()
            }
            return
        }

        guard analysisTask == nil else {
            return
        }

        let permissions = textIngestionMode == .legacyScreenCapture
            ? permissionManager.status()
            : PermissionStatus(accessibility: false, screenRecording: false)
        let analysisTarget = AnalysisTarget(window)
        let minimumMeaningfulTextLength = config.minimumMeaningfulTextLength
        let preferAccessibility = role == .primary || window.isFocused

        analysisTask = Task { [weak self] in
            guard let self else {
                return
            }

            let extraction = await analysisWorker.extractObservation(
                for: window,
                permissions: permissions,
                minimumMeaningfulTextLength: minimumMeaningfulTextLength,
                preferAccessibility: preferAccessibility
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
        guard overlayEffectPhase == .alive else {
            return
        }

        if let observation = extraction.observation {
            textBuffer.append(observation, now: observation.timestamp)
        } else {
            textBuffer.prune()
        }

        let previousState = companionState
        let previousActivity = activityState
        let previousPresentation = presentationState
        let previousAngerScore = angerScore
        let previousEffectiveState = effectiveCompanionState
        let previousStickerName = activeStickerName
        let result = sentimentEngine.analyze(
            observations: textBuffer.observations,
            previousAngerScore: angerScore,
            previousState: companionState
        )

        angerScore = result.finalAngerScore
        companionState = result.currentState
        activityState = activityClassifier.classify(
            observations: textBuffer.observations,
            sentimentResult: result,
            config: config
        )
        lastMatchedTriggers = result.matchedTriggers
        let stickerChangeReason = updateStickerIfNeeded(
            matchedTriggers: result.matchedTriggers,
            previousState: previousState,
            currentState: result.currentState,
            previousActivity: previousActivity,
            currentActivity: activityState,
            hasFreshObservation: extraction.observation == nil ? false : true
        )
        activeQuip = nextQuip(
            matchedTriggers: result.matchedTriggers,
            previousState: previousState,
            currentState: result.currentState,
            previousActivity: previousActivity,
            currentActivity: activityState
        )
        rebuildPresentationState()

        let didExplode = triggerExplosion(
            window: window,
            previousPresentation: previousPresentation,
            force: false
        )

        debugMonitor.recordAnalysis(
            extraction: extraction.reason,
            observation: extraction.observation,
            previousAngerScore: previousAngerScore,
            angerScore: angerScore,
            previousState: previousEffectiveState,
            state: effectiveCompanionState,
            previousStickerName: previousStickerName,
            stickerName: activeStickerName,
            triggers: result.matchedTriggers,
            quip: activeQuip,
            stickerChangeReason: stickerChangeReason
        )

        if didExplode {
            notifySnapshotChanged()
            return
        }

        playSoundEvents(
            OverlaySoundEventDetector.events(
                from: previousPresentation,
                to: presentationState,
                didExplode: false
            )
        )
        overlayController.present(window: window, presentation: presentationState)
        notifySnapshotChanged()
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
        currentState: CompanionState,
        previousActivity: SessionActivityState,
        currentActivity: SessionActivityState
    ) -> String? {
        let now = Date()

        if currentActivity == .reading || currentActivity == .thinking {
            lastQuipDate = nil
            return nil
        }

        if currentState == .calm, currentActivity == .default, angerScore < 15 {
            lastQuipDate = nil
            return nil
        }

        let cooledDown = lastQuipDate.map { now.timeIntervalSince($0) >= config.quipCooldown } ?? true
        let presentationChanged = previousState != currentState || previousActivity != currentActivity
        let sustainedNotableState = angerScore >= 65 || currentActivity == .blocked || currentActivity == .celebrating

        guard presentationChanged || (sustainedNotableState && cooledDown) else {
            return activeQuip
        }

        let quip = CompanionPersona.quip(
            for: currentState,
            activity: currentActivity,
            triggers: matchedTriggers
        )
        lastQuipDate = quip == nil ? nil : now
        return quip
    }

    private func updateStickerIfNeeded(
        matchedTriggers: [String],
        previousState: CompanionState,
        currentState: CompanionState,
        previousActivity: SessionActivityState,
        currentActivity: SessionActivityState,
        hasFreshObservation: Bool
    ) -> String? {
        guard overlayEffectPhase == .alive else {
            return nil
        }

        let now = Date()
        let stateChanged = previousState != currentState
        let activityChanged = previousActivity != currentActivity
        let canRotateSticker = nextStickerChangeDate.map { now >= $0 } ?? true

        guard activeStickerName == nil || stateChanged || activityChanged || (hasFreshObservation && canRotateSticker) else {
            return nil
        }

        let reason: String
        if activeStickerName == nil {
            reason = "initial"
        } else if stateChanged {
            reason = "state_changed"
        } else if activityChanged {
            reason = "activity_changed"
        } else {
            reason = "new_message_rotation"
        }

        activeStickerName = CompanionPersona.stickerName(
            for: currentState,
            activity: currentActivity,
            triggers: matchedTriggers,
            previousStickerName: activeStickerName
        )
        nextStickerChangeDate = now.addingTimeInterval(
            Double.random(in: config.stickerHoldMinimum...config.stickerHoldMaximum)
        )
        return reason
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
        let names = ["default"] + SessionActivityState.allCases.flatMap { activity in
            CompanionState.allCases.map { CompanionPersona.defaultSticker(for: $0, activity: activity) }
        }
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
        guard allowsDisplayLinkedRefresh,
              let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }

        return config.targetBundleIDs.contains(bundleID)
    }

    private func rebuildPresentationState() {
        let stickerName = activeStickerName ?? CompanionPersona.defaultSticker(
            for: companionState,
            activity: activityState
        )
        activeStickerName = stickerName

        presentationState = OverlayPresentationState(
            emotion: effectiveCompanionState,
            activity: activityState,
            angerScore: angerScore,
            stickerName: stickerName,
            quip: overlayEffectPhase == .alive ? activeQuip : nil,
            effectPhase: overlayEffectPhase,
            badgeText: role == .spawned ? displayTag : nil
        )
    }

    @discardableResult
    private func triggerExplosion(
        window: TrackedWindow,
        previousPresentation: OverlayPresentationState,
        force: Bool
    ) -> Bool {
        guard overlayEffectPhase == .alive else {
            return false
        }

        guard force || explosionMonitor.shouldExplode(
            emotion: companionState,
            angerScore: angerScore,
            now: Date()
        ) else {
            return false
        }

        explosionMonitor.resetTracking()
        overlayEffectPhase = .exploding
        activeQuip = nil
        rebuildPresentationState()

        playSoundEvents(
            OverlaySoundEventDetector.events(
                from: previousPresentation,
                to: presentationState,
                didExplode: true
            )
        )
        overlayController.present(window: window, presentation: presentationState)
        scheduleExplosionEffectLifecycle()
        onExplosion?(snapshot())

        return true
    }

    private func scheduleExplosionEffectLifecycle() {
        effectTask?.cancel()

        effectTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            defer {
                self.effectTask = nil
            }

            try? await Task.sleep(for: .seconds(explosionAnimationDuration))
            guard !Task.isCancelled else {
                return
            }

            self.transitionToTombstone()

            try? await Task.sleep(for: .seconds(config.tombstoneDuration))
            guard !Task.isCancelled else {
                return
            }

            self.resetAfterExplosion()
        }
    }

    private func transitionToTombstone() {
        guard overlayEffectPhase == .exploding else {
            return
        }

        overlayEffectPhase = .tombstone
        rebuildPresentationState()
        presentCurrentState()
        notifySnapshotChanged()
    }

    private func resetAfterExplosion() {
        overlayEffectPhase = .alive
        angerScore = 0
        companionState = .calm
        activityState = .default
        activeQuip = nil
        lastMatchedTriggers = []
        lastQuipDate = nil
        nextStickerChangeDate = nil
        activeStickerName = CompanionPersona.defaultSticker(for: .calm, activity: .default)
        textBuffer.clear()
        explosionMonitor.startCooldown(now: Date())
        rebuildPresentationState()
        presentCurrentState()
        notifySnapshotChanged()
    }

    private func playSoundEvents(_ events: [SoundEffectEvent]) {
        for event in events {
            soundEffectPlayer.play(event)
        }
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
    private let textIngestionMode: TextIngestionMode
    private let codexRolloutSource: CodexRolloutTextSource?
    private let accessibilityExtractor = AccessibilityTextExtractor()
    private let ocrService = WindowOCRService()

    init(
        textIngestionMode: TextIngestionMode,
        codexRolloutSource: CodexRolloutTextSource?
    ) {
        self.textIngestionMode = textIngestionMode
        self.codexRolloutSource = codexRolloutSource
    }

    func extractObservation(
        for window: TrackedWindow,
        permissions: PermissionStatus,
        minimumMeaningfulTextLength: Int,
        preferAccessibility: Bool
    ) async -> SessionObservationExtraction {
        if Task.isCancelled {
            return SessionObservationExtraction(observation: nil, reason: "cancelled")
        }

        if textIngestionMode == .codexSessions {
            if let codexObservation = await codexRolloutSource?.nextObservation(
                minimumMeaningfulTextLength: minimumMeaningfulTextLength
            ) {
                return SessionObservationExtraction(
                    observation: codexObservation,
                    reason: "codex_sessions"
                )
            }

            return SessionObservationExtraction(observation: nil, reason: "codex_sessions_empty")
        }

        let now = Date()

        if preferAccessibility,
           permissions.accessibility,
           let rawText = accessibilityExtractor.extractText(
                forBundleIdentifier: window.bundleID,
                appName: window.appName,
                windowTitle: window.title
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
        } else if preferAccessibility {
            reasons.append("accessibility_empty_or_short")
        } else {
            reasons.append("accessibility_skipped")
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

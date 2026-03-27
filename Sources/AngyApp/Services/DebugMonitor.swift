import AngyCore
import Foundation

@MainActor
final class DebugMonitor {
    static let shared = DebugMonitor()

    private let isEnabled: Bool
    private var overlayTickCount = 0
    private var analysisTickCount = 0
    private var lastRateLogDate = Date()
    private var lastVisibility = false
    private var lastLoggedState: CompanionState?
    private var lastStickerName: String?

    private init() {
        let environment = ProcessInfo.processInfo.environment
        isEnabled = environment["ANGY_DEBUG"] == "1"
    }

    var isEnabledForUI: Bool {
        isEnabled
    }

    func announceIfEnabled() {
        guard isEnabled else { return }
        log("debug logging enabled")
        log("ascii panda + hamster sidecar mode active")
    }

    func recordOverlay(window: TrackedWindow?, state: CompanionState) {
        guard isEnabled else { return }

        overlayTickCount += 1
        maybeLogRates()

        let isVisible = window != nil
        if isVisible != lastVisibility {
            if let window {
                log("overlay visible window_id=\(window.windowID) frame=\(format(rect: window.frame))")
            } else {
                log("overlay hidden")
            }
            lastVisibility = isVisible
        }

        if lastLoggedState != state {
            log("overlay state=\(state.rawValue)")
            lastLoggedState = state
        }
    }

    func recordAnalysis(
        extraction: String,
        observation: TextObservation?,
        angerScore: Double,
        state: CompanionState,
        stickerName: String?,
        triggers: [String],
        quip: String?
    ) {
        guard isEnabled else { return }

        analysisTickCount += 1
        maybeLogRates()

        let characters = observation?.rawText.count ?? 0
        let confidence = observation.map { String(format: "%.2f", $0.confidence) } ?? "-"
        let score = String(format: "%.1f", angerScore)
        let triggerSummary: String
        if triggers.isEmpty {
            triggerSummary = "-"
        } else {
            let uniqueTriggers = Array(NSOrderedSet(array: triggers)) as? [String] ?? triggers
            let preview = uniqueTriggers.prefix(5).joined(separator: ",")
            triggerSummary = "\(preview) total=\(triggers.count)"
        }
        let quipSummary = quip ?? "-"
        let stickerSummary = stickerName ?? "-"

        if lastStickerName != stickerName, let stickerName {
            log("sticker changed name=\(stickerName)")
            lastStickerName = stickerName
        }

        log(
            "analysis source=\(extraction) chars=\(characters) confidence=\(confidence) anger=\(score) state=\(state.rawValue) sticker=\(stickerSummary) triggers=\(triggerSummary) quip=\(quipSummary)"
        )
    }

    func recordStickerAsset(name: String, loaded: Bool, size: CGSize?) {
        guard isEnabled else { return }

        if let size {
            log(
                "sticker asset name=\(name) loaded=\(loaded) size=\(Int(size.width))x\(Int(size.height))"
            )
        } else {
            log("sticker asset name=\(name) loaded=\(loaded)")
        }
    }

    private func maybeLogRates() {
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRateLogDate)
        guard elapsed >= 1 else { return }

        let overlayFPS = Double(overlayTickCount) / elapsed
        let analysisHz = Double(analysisTickCount) / elapsed

        log(
            "rates overlay_fps=\(String(format: "%.1f", overlayFPS)) analysis_hz=\(String(format: "%.1f", analysisHz))"
        )

        overlayTickCount = 0
        analysisTickCount = 0
        lastRateLogDate = now
    }

    private func log(_ message: String) {
        print("[AngyDebug] \(message)")
    }

    private func format(rect: CGRect) -> String {
        "x=\(Int(rect.origin.x)) y=\(Int(rect.origin.y)) w=\(Int(rect.width)) h=\(Int(rect.height))"
    }
}

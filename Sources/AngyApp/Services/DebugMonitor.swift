import AngyCore
import Foundation

@MainActor
final class DebugMonitor {
    static let shared = DebugMonitor()

    private let isEnabled: Bool
    private let isVerboseEnabled: Bool
    private var overlayTickCount = 0
    private var analysisTickCount = 0
    private var lastRateLogDate = Date()
    private var lastVisibility = false
    private var lastLoggedState: CompanionState?
    private var lastExtractionReason: String?
    private var lastObservationSignature: String?
    private var lastTriggerSignature: String?
    private var lastQuip: String?

    private init() {
        let environment = ProcessInfo.processInfo.environment
        isEnabled = environment["ANGY_DEBUG"] == "1"
        isVerboseEnabled = environment["ANGY_DEBUG_VERBOSE"] == "1"
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
        previousAngerScore: Double,
        angerScore: Double,
        previousState: CompanionState,
        state: CompanionState,
        previousStickerName: String?,
        stickerName: String?,
        triggers: [String],
        quip: String?,
        stickerChangeReason: String?
    ) {
        guard isEnabled else { return }

        analysisTickCount += 1
        maybeLogRates()

        let characters = observation?.rawText.count ?? 0
        let confidence = observation.map { String(format: "%.2f", $0.confidence) } ?? "-"
        let previousScore = String(format: "%.1f", previousAngerScore)
        let score = String(format: "%.1f", angerScore)
        let preview = observation.map(previewText(from:)) ?? "-"
        let uniqueTriggers = uniquePreservingOrder(triggers)
        let triggerSummary = triggerSummary(for: uniqueTriggers, totalCount: triggers.count)
        let triggerSignature = uniqueTriggers.joined(separator: "|")

        if extraction != lastExtractionReason {
            log("analysis source=\(extraction)")
            lastExtractionReason = extraction
        }

        let observationSignature = observation.map { "\($0.source.rawValue)|\($0.normalizedText)" }
        if observationSignature != lastObservationSignature, let observation {
            log(
                "message observed source=\(observation.source.rawValue) chars=\(characters) confidence=\(confidence) preview=\(preview)"
            )
            lastObservationSignature = observationSignature
        } else if observation == nil {
            lastObservationSignature = nil
        }

        if triggerSignature != lastTriggerSignature, !uniqueTriggers.isEmpty {
            log("triggers updated value=\(triggerSummary)")
            lastTriggerSignature = triggerSignature
        } else if uniqueTriggers.isEmpty {
            lastTriggerSignature = nil
        }

        if previousState != state {
            log(
                "emotion changed from=\(previousState.rawValue) to=\(state.rawValue) anger=\(previousScore)->\(score) triggers=\(triggerSummary) preview=\(preview)"
            )
        }

        if previousStickerName != stickerName, let stickerName {
            let previousSticker = previousStickerName ?? "-"
            let reason = stickerChangeReason ?? "unspecified"
            log(
                "sticker changed from=\(previousSticker) to=\(stickerName) reason=\(reason) state=\(state.rawValue)"
            )
        }

        if quip != lastQuip {
            let quipSummary = quip ?? "-"
            log("quip changed text=\(quipSummary)")
            lastQuip = quip
        }
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
        guard isVerboseEnabled else { return }

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

    private func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var unique: [String] = []
        unique.reserveCapacity(values.count)

        for value in values where seen.insert(value).inserted {
            unique.append(value)
        }

        return unique
    }

    private func triggerSummary(for uniqueTriggers: [String], totalCount: Int) -> String {
        guard !uniqueTriggers.isEmpty else {
            return "-"
        }

        let preview = uniqueTriggers.prefix(5).joined(separator: ",")
        return "\(preview) total=\(totalCount)"
    }

    private func previewText(from observation: TextObservation) -> String {
        let lines = observation.rawText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)

        let joined = lines.joined(separator: " | ")
        guard !joined.isEmpty else {
            return "-"
        }

        let compact = joined.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        if compact.count <= 160 {
            return compact
        }

        let endIndex = compact.index(compact.startIndex, offsetBy: 160)
        return String(compact[..<endIndex]) + "..."
    }

    private func format(rect: CGRect) -> String {
        "x=\(Int(rect.origin.x)) y=\(Int(rect.origin.y)) w=\(Int(rect.width)) h=\(Int(rect.height))"
    }
}

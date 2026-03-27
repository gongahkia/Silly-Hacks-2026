import AngyCore
import Foundation

enum OverlayEffectPhase: String, Sendable, Equatable {
    case alive
    case exploding
    case tombstone
}

enum RageMeterBand: String, Sendable, Equatable, CaseIterable {
    case calm
    case curious
    case annoyed
    case furious
    case critical

    static func band(for angerScore: Double) -> RageMeterBand {
        switch angerScore {
        case ..<25:
            return .calm
        case ..<45:
            return .curious
        case ..<70:
            return .annoyed
        case ..<95:
            return .furious
        default:
            return .critical
        }
    }
}

struct OverlayPresentationState: Sendable, Equatable {
    let emotion: CompanionState
    let activity: SessionActivityState
    let angerScore: Double
    let stickerName: String
    let quip: String?
    let effectPhase: OverlayEffectPhase

    var rageMeterBand: RageMeterBand {
        RageMeterBand.band(for: angerScore)
    }

    static func calmDefault(stickerName: String) -> OverlayPresentationState {
        OverlayPresentationState(
            emotion: .calm,
            activity: .default,
            angerScore: 0,
            stickerName: stickerName,
            quip: nil,
            effectPhase: .alive
        )
    }
}

enum SoundEffectEvent: String, Sendable, CaseIterable {
    case blocked
    case furious
    case critical
    case explode
}

enum OverlaySoundEventDetector {
    static func events(
        from previous: OverlayPresentationState?,
        to current: OverlayPresentationState,
        didExplode: Bool
    ) -> [SoundEffectEvent] {
        var events: [SoundEffectEvent] = []

        if previous?.activity != .blocked, current.activity == .blocked {
            events.append(.blocked)
        }

        if previous?.emotion != .furious, current.emotion == .furious {
            events.append(.furious)
        }

        if previous?.rageMeterBand != .critical, current.rageMeterBand == .critical {
            events.append(.critical)
        }

        if didExplode {
            events.append(.explode)
        }

        return events
    }
}

struct ExplosionMonitor: Sendable {
    private let threshold: Double
    private let holdDuration: TimeInterval
    private let cooldownDuration: TimeInterval

    private(set) var criticalStartDate: Date?
    private(set) var cooldownUntil: Date?

    init(config: AppConfig) {
        threshold = config.explosionThreshold
        holdDuration = config.explosionHoldDuration
        cooldownDuration = config.explosionCooldown
    }

    mutating func shouldExplode(
        emotion: CompanionState,
        angerScore: Double,
        now: Date
    ) -> Bool {
        if let cooldownUntil, now < cooldownUntil {
            return false
        }

        guard emotion == .furious, angerScore >= threshold else {
            criticalStartDate = nil
            return false
        }

        if criticalStartDate == nil {
            criticalStartDate = now
            return false
        }

        return now.timeIntervalSince(criticalStartDate ?? now) >= holdDuration
    }

    mutating func resetTracking() {
        criticalStartDate = nil
    }

    mutating func startCooldown(now: Date) {
        criticalStartDate = nil
        cooldownUntil = now.addingTimeInterval(cooldownDuration)
    }
}

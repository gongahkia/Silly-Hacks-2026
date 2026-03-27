import AngyCore
import Foundation

enum CompanionPersona {
    private struct CatalogueKey: Hashable {
        let emotion: CompanionState
        let activity: SessionActivityState
    }

    private enum QuipPolicy {
        case emotionDriven
        case silent
        case blocked
        case celebrating
    }

    private struct CatalogueEntry {
        let preferredStickers: [String]
        let quipPolicy: QuipPolicy
    }

    private static let catalogue: [CatalogueKey: CatalogueEntry] = {
        var entries: [CatalogueKey: CatalogueEntry] = [:]

        for emotion in CompanionState.allCases {
            entries[CatalogueKey(emotion: emotion, activity: .default)] = CatalogueEntry(
                preferredStickers: [],
                quipPolicy: .emotionDriven
            )
            entries[CatalogueKey(emotion: emotion, activity: .reading)] = CatalogueEntry(
                preferredStickers: ["love", "happy"],
                quipPolicy: .silent
            )
            entries[CatalogueKey(emotion: emotion, activity: .thinking)] = CatalogueEntry(
                preferredStickers: ["confused-2", "confused-1"],
                quipPolicy: .silent
            )
            entries[CatalogueKey(emotion: emotion, activity: .celebrating)] = CatalogueEntry(
                preferredStickers: ["love", "happy", "correction"],
                quipPolicy: .celebrating
            )
        }

        for emotion in CompanionState.allCases {
            let blockedStickers: [String]
            switch emotion {
            case .furious:
                blockedStickers = ["anger", "lost-it", "given-up", "aghast"]
            case .annoyed:
                blockedStickers = ["exasperated", "incorrect", "sad", "correction"]
            case .calm, .curious:
                blockedStickers = ["incorrect", "exasperated", "sad", "correction"]
            }

            entries[CatalogueKey(emotion: emotion, activity: .blocked)] = CatalogueEntry(
                preferredStickers: blockedStickers,
                quipPolicy: .blocked
            )
        }

        return entries
    }()

    static func pose(for state: CompanionState, bobPhase: Int) -> String {
        switch (state, bobPhase) {
        case (.calm, 0):
            return """
              /^-^\\
             _( -.-)
              /|_|\\
            """
        case (.calm, _):
            return """
               /^-^\\
              _( -.-)
               /|_|\\
            """
        case (.curious, 0):
            return """
              /^o^\\
             _( o.o)
              /|_|\\
            """
        case (.curious, _):
            return """
               /^o^\\
              _( o.o)
               /|_|\\
            """
        case (.annoyed, 0):
            return """
              /^>^\\
             _( -_-')
              /|_|\\
            """
        case (.annoyed, _):
            return """
               /^>^\\
              _( -_-')
               /|_|\\
            """
        case (.furious, 0):
            return """
              /^!^\\
             _( >:O)
              /|_|\\
            """
        case (.furious, _):
            return """
               /^!^\\
              _( >:O)
               /|_|\\
            """
        }
    }

    static func quip(
        for state: CompanionState,
        activity: SessionActivityState,
        triggers: [String]
    ) -> String? {
        let joinedTriggers = triggers.joined(separator: " ")
        let key = CatalogueKey(emotion: state, activity: activity)
        let policy = catalogue[key]?.quipPolicy ?? .emotionDriven

        switch policy {
        case .silent:
            return nil
        case .celebrating:
            if joinedTriggers.contains("fixed") || joinedTriggers.contains("passed") || joinedTriggers.contains("success") {
                return "nice. that landed."
            }
            return "finally, a win."
        case .blocked:
            if joinedTriggers.contains("repeat:") {
                return "we've done this already."
            }
            if joinedTriggers.contains("timeout") {
                return "stuck again."
            }
            if joinedTriggers.contains("error") || joinedTriggers.contains("failed") {
                return "excellent. another fire."
            }
            return "this smells broken."
        case .emotionDriven:
            return emotionDrivenQuip(for: state, joinedTriggers: joinedTriggers)
        }
    }

    static func defaultSticker(
        for state: CompanionState,
        activity: SessionActivityState = .default
    ) -> String {
        stickerPool(
            for: state,
            activity: activity,
            triggers: []
        ).first ?? emotionDefaultStickers(for: state).first ?? "happy"
    }

    static func stickerName(
        for state: CompanionState,
        activity: SessionActivityState,
        triggers: [String],
        previousStickerName: String?
    ) -> String {
        let pool = stickerPool(for: state, activity: activity, triggers: triggers)

        guard let previousStickerName,
              let currentIndex = pool.firstIndex(of: previousStickerName),
              pool.count > 1 else {
            return pool.first ?? defaultSticker(for: state, activity: activity)
        }

        return pool[(currentIndex + 1) % pool.count]
    }

    static func assetSource(for stickerName: String) -> StickerAssetSource? {
        StickerAssetCatalog.asset(named: stickerName)
    }

    private static func emotionDrivenQuip(for state: CompanionState, joinedTriggers: String) -> String {
        switch state {
        case .calm:
            return joinedTriggers.contains("fixed") || joinedTriggers.contains("success")
                ? "we survived."
                : "stable enough."
        case .curious:
            return joinedTriggers.contains("why") ? "good question." : "something shifted."
        case .annoyed:
            return joinedTriggers.contains("repeat:") ? "we've done this already." : "this smells broken."
        case .furious:
            if joinedTriggers.contains("timeout") {
                return "time itself is mocking you."
            }
            if joinedTriggers.contains("error") || joinedTriggers.contains("failed") {
                return "excellent. another fire."
            }
            return "this session is spiraling."
        }
    }

    private static func preferredSticker(for state: CompanionState, triggers: [String]) -> String? {
        let joinedTriggers = triggers.joined(separator: " ")

        if joinedTriggers.contains("fixed") || joinedTriggers.contains("success") || joinedTriggers.contains("passed") {
            return "happy"
        }

        if joinedTriggers.contains("timeout") {
            return "aghast"
        }

        if joinedTriggers.contains("error") || joinedTriggers.contains("failed") {
            return state == .furious ? "anger" : "incorrect"
        }

        if joinedTriggers.contains("why") || joinedTriggers.contains("???") {
            return state == .furious ? "shocked" : "confused-1"
        }

        if joinedTriggers.contains("repeat:") || joinedTriggers.contains("still") {
            return state == .furious ? "given-up" : "exasperated"
        }

        return nil
    }

    private static func stickerPool(
        for state: CompanionState,
        activity: SessionActivityState,
        triggers: [String]
    ) -> [String] {
        let key = CatalogueKey(emotion: state, activity: activity)
        let activityEntry = catalogue[key] ?? CatalogueEntry(preferredStickers: [], quipPolicy: .emotionDriven)
        let triggerPreferred = preferredSticker(for: state, triggers: triggers)
        let emotionDefaults = emotionDefaultStickers(for: state)
        var ordered: [String] = []

        if activity == .default || activity == .blocked, let triggerPreferred {
            ordered.append(triggerPreferred)
        }

        ordered.append(contentsOf: activityEntry.preferredStickers)

        if activity != .default, activity != .blocked, let triggerPreferred {
            ordered.append(triggerPreferred)
        }

        ordered.append(contentsOf: emotionDefaults)

        var deduplicated: [String] = []
        var seen = Set<String>()

        for stickerName in ordered where seen.insert(stickerName).inserted {
            deduplicated.append(stickerName)
        }

        return deduplicated
    }

    private static func emotionDefaultStickers(for state: CompanionState) -> [String] {
        switch state {
        case .calm:
            return ["happy", "love", "sad"]
        case .curious:
            return ["confused-1", "confused-2", "shocked", "correction"]
        case .annoyed:
            return ["exasperated", "incorrect", "sad", "correction"]
        case .furious:
            return ["anger", "lost-it", "given-up", "aghast"]
        }
    }
}

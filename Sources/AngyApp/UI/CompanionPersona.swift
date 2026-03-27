import AngyCore
import AppKit
import Foundation

enum CompanionPersona {
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

    static func quip(for state: CompanionState, triggers: [String]) -> String {
        let joinedTriggers = triggers.joined(separator: " ")

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

    static func defaultSticker(for state: CompanionState) -> String {
        switch state {
        case .calm:
            return "happy"
        case .curious:
            return "confused-1"
        case .annoyed:
            return "exasperated"
        case .furious:
            return "anger"
        }
    }

    static func stickerName(
        for state: CompanionState,
        triggers: [String],
        previousStickerName: String?
    ) -> String {
        let preferred = preferredSticker(for: state, triggers: triggers)
        let pool = stickerPool(for: state, preferred: preferred)

        guard let previousStickerName,
              let currentIndex = pool.firstIndex(of: previousStickerName),
              pool.count > 1 else {
            return pool.first ?? defaultSticker(for: state)
        }

        return pool[(currentIndex + 1) % pool.count]
    }

    static func image(for stickerName: String) -> NSImage? {
        guard let url = Bundle.module.url(
            forResource: stickerName,
            withExtension: "png",
            subdirectory: "Stickers"
        ) else {
            return nil
        }

        return NSImage(contentsOf: url)
    }

    private static func preferredSticker(for state: CompanionState, triggers: [String]) -> String {
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

        switch state {
        case .calm:
            return "happy"
        case .curious:
            return "confused-2"
        case .annoyed:
            return "exasperated"
        case .furious:
            return "lost-it"
        }
    }

    private static func stickerPool(for state: CompanionState, preferred: String) -> [String] {
        let defaults: [String]

        switch state {
        case .calm:
            defaults = ["happy", "love", "sad"]
        case .curious:
            defaults = ["confused-1", "confused-2", "shocked", "correction"]
        case .annoyed:
            defaults = ["exasperated", "incorrect", "sad", "correction"]
        case .furious:
            defaults = ["anger", "lost-it", "given-up", "aghast"]
        }

        return [preferred] + defaults.filter { $0 != preferred }
    }
}

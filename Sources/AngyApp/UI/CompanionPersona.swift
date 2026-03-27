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
            return "stable enough."
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

    static func color(for state: CompanionState) -> NSColor {
        switch state {
        case .calm:
            return NSColor(calibratedRed: 0.56, green: 0.88, blue: 0.85, alpha: 0.98)
        case .curious:
            return NSColor(calibratedRed: 0.66, green: 0.83, blue: 1.0, alpha: 0.98)
        case .annoyed:
            return NSColor(calibratedRed: 1.0, green: 0.73, blue: 0.42, alpha: 0.99)
        case .furious:
            return NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.38, alpha: 0.99)
        }
    }
}

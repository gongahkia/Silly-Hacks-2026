import CoreGraphics
import Foundation

public enum TextSource: String, Sendable, CaseIterable {
    case accessibility
    case ocr
}

public struct TrackedWindow: Sendable, Equatable {
    public var bundleID: String
    public var appName: String
    public var windowID: UInt32
    public var frame: CGRect
    public var screenID: String?
    public var isVisible: Bool
    public var title: String?

    public init(
        bundleID: String,
        appName: String,
        windowID: UInt32,
        frame: CGRect,
        screenID: String?,
        isVisible: Bool,
        title: String?
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.windowID = windowID
        self.frame = frame
        self.screenID = screenID
        self.isVisible = isVisible
        self.title = title
    }
}

public struct TextObservation: Sendable, Equatable {
    public var timestamp: Date
    public var source: TextSource
    public var rawText: String
    public var normalizedText: String
    public var confidence: Double

    public init(
        timestamp: Date,
        source: TextSource,
        rawText: String,
        normalizedText: String,
        confidence: Double
    ) {
        self.timestamp = timestamp
        self.source = source
        self.rawText = rawText
        self.normalizedText = normalizedText
        self.confidence = confidence
    }
}

public enum CompanionState: String, Sendable, CaseIterable {
    case calm
    case curious
    case annoyed
    case furious
}

public struct SentimentResult: Sendable, Equatable {
    public var baseSentimentScore: Double
    public var heuristicAdjustment: Double
    public var finalAngerScore: Double
    public var matchedTriggers: [String]
    public var currentState: CompanionState

    public init(
        baseSentimentScore: Double,
        heuristicAdjustment: Double,
        finalAngerScore: Double,
        matchedTriggers: [String],
        currentState: CompanionState
    ) {
        self.baseSentimentScore = baseSentimentScore
        self.heuristicAdjustment = heuristicAdjustment
        self.finalAngerScore = finalAngerScore
        self.matchedTriggers = matchedTriggers
        self.currentState = currentState
    }
}

public struct ReactionEvent: Sendable, Equatable {
    public var fromState: CompanionState?
    public var toState: CompanionState
    public var asciiPose: String
    public var quip: String?
    public var displayDuration: TimeInterval

    public init(
        fromState: CompanionState?,
        toState: CompanionState,
        asciiPose: String,
        quip: String?,
        displayDuration: TimeInterval
    ) {
        self.fromState = fromState
        self.toState = toState
        self.asciiPose = asciiPose
        self.quip = quip
        self.displayDuration = displayDuration
    }
}

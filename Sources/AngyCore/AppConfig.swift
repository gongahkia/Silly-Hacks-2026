import CoreGraphics
import Foundation

public struct AppConfig: Sendable, Equatable {
    public var targetBundleIDs: Set<String>
    public var targetOwnerNames: Set<String>
    public var overlayRefreshInterval: TimeInterval
    public var textRefreshInterval: TimeInterval
    public var rollingWindowDuration: TimeInterval
    public var overlayOffset: CGSize
    public var overlayInsideFallbackPadding: CGFloat
    public var quipCooldown: TimeInterval
    public var smoothingFactor: Double
    public var decayFactor: Double
    public var hysteresis: Double
    public var stickerHoldMinimum: TimeInterval
    public var stickerHoldMaximum: TimeInterval
    public var calmUpperBound: Double
    public var curiousUpperBound: Double
    public var annoyedUpperBound: Double
    public var minimumMeaningfulTextLength: Int

    public init(
        targetBundleIDs: Set<String>,
        targetOwnerNames: Set<String>,
        overlayRefreshInterval: TimeInterval,
        textRefreshInterval: TimeInterval,
        rollingWindowDuration: TimeInterval,
        overlayOffset: CGSize,
        overlayInsideFallbackPadding: CGFloat,
        quipCooldown: TimeInterval,
        smoothingFactor: Double,
        decayFactor: Double,
        hysteresis: Double,
        stickerHoldMinimum: TimeInterval,
        stickerHoldMaximum: TimeInterval,
        calmUpperBound: Double,
        curiousUpperBound: Double,
        annoyedUpperBound: Double,
        minimumMeaningfulTextLength: Int
    ) {
        self.targetBundleIDs = targetBundleIDs
        self.targetOwnerNames = targetOwnerNames
        self.overlayRefreshInterval = overlayRefreshInterval
        self.textRefreshInterval = textRefreshInterval
        self.rollingWindowDuration = rollingWindowDuration
        self.overlayOffset = overlayOffset
        self.overlayInsideFallbackPadding = overlayInsideFallbackPadding
        self.quipCooldown = quipCooldown
        self.smoothingFactor = smoothingFactor
        self.decayFactor = decayFactor
        self.hysteresis = hysteresis
        self.stickerHoldMinimum = stickerHoldMinimum
        self.stickerHoldMaximum = stickerHoldMaximum
        self.calmUpperBound = calmUpperBound
        self.curiousUpperBound = curiousUpperBound
        self.annoyedUpperBound = annoyedUpperBound
        self.minimumMeaningfulTextLength = minimumMeaningfulTextLength
    }
}

public extension AppConfig {
    static let live = AppConfig(
        targetBundleIDs: ["com.openai.codex", "com.mitchellh.ghostty", "com.cmuxterm.app"],
        targetOwnerNames: ["Codex", "Ghostty", "ghostty", "cmux", "Cmux"],
        overlayRefreshInterval: 1.0 / 60.0,
        textRefreshInterval: 1.0,
        rollingWindowDuration: 20.0,
        overlayOffset: CGSize(width: 80, height: 14),
        overlayInsideFallbackPadding: 14,
        quipCooldown: 10.0,
        smoothingFactor: 0.78,
        decayFactor: 0.82,
        hysteresis: 8,
        stickerHoldMinimum: 3.0,
        stickerHoldMaximum: 5.0,
        calmUpperBound: 24,
        curiousUpperBound: 44,
        annoyedUpperBound: 69,
        minimumMeaningfulTextLength: 40
    )
}

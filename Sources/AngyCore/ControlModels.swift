import CoreGraphics
import Foundation

public struct AngyInstanceID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: StringLiteralType) {
        rawValue = value
    }
}

public enum AngyInstanceRole: String, Codable, Sendable, CaseIterable {
    case primary
    case spawned
}

public struct AngyRect: Codable, Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct AngyWindowRef: Codable, Sendable, Equatable {
    public var windowID: UInt32
    public var bundleID: String
    public var appName: String
    public var title: String?
    public var frame: AngyRect
    public var isVisible: Bool
    public var isFocused: Bool

    public init(
        windowID: UInt32,
        bundleID: String,
        appName: String,
        title: String?,
        frame: AngyRect,
        isVisible: Bool,
        isFocused: Bool
    ) {
        self.windowID = windowID
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.frame = frame
        self.isVisible = isVisible
        self.isFocused = isFocused
    }

    public init(window: TrackedWindow) {
        self.init(
            windowID: window.windowID,
            bundleID: window.bundleID,
            appName: window.appName,
            title: window.title,
            frame: AngyRect(window.frame),
            isVisible: window.isVisible,
            isFocused: window.isFocused
        )
    }
}

public struct AngyInstanceSnapshot: Codable, Sendable, Equatable {
    public var id: AngyInstanceID
    public var role: AngyInstanceRole
    public var tag: String?
    public var target: AngyWindowRef?
    public var emotion: CompanionState
    public var activity: SessionActivityState
    public var angerScore: Double
    public var paused: Bool
    public var effectPhase: String
    public var quip: String?
    public var matchedTriggers: [String]

    public init(
        id: AngyInstanceID,
        role: AngyInstanceRole,
        tag: String?,
        target: AngyWindowRef?,
        emotion: CompanionState,
        activity: SessionActivityState,
        angerScore: Double,
        paused: Bool,
        effectPhase: String,
        quip: String?,
        matchedTriggers: [String]
    ) {
        self.id = id
        self.role = role
        self.tag = tag
        self.target = target
        self.emotion = emotion
        self.activity = activity
        self.angerScore = angerScore
        self.paused = paused
        self.effectPhase = effectPhase
        self.quip = quip
        self.matchedTriggers = matchedTriggers
    }
}

public struct AngyGlobalSettingsSnapshot: Codable, Sendable, Equatable {
    public var pauseAll: Bool
    public var hateMailEnabled: Bool
    public var soundEnabled: Bool

    public init(
        pauseAll: Bool,
        hateMailEnabled: Bool,
        soundEnabled: Bool
    ) {
        self.pauseAll = pauseAll
        self.hateMailEnabled = hateMailEnabled
        self.soundEnabled = soundEnabled
    }
}

public enum AngyControlAction: String, Codable, Sendable, CaseIterable {
    case listWindows
    case listInstances
    case spawnFrontmost
    case spawnWindow
    case removeInstance
    case pauseInstance
    case resumeInstance
    case pauseAll
    case resumeAll
    case retargetInstance
    case setOverrideState
    case clearOverrideState
    case explodeInstance
    case writeHateMail
    case getSettings
    case setSetting
}

public struct AngyControlRequest: Codable, Sendable, Equatable {
    public var action: AngyControlAction
    public var instanceID: AngyInstanceID?
    public var instanceTag: String?
    public var windowID: UInt32?
    public var settingKey: String?
    public var settingValue: String?
    public var overrideState: CompanionState?

    public init(
        action: AngyControlAction,
        instanceID: AngyInstanceID? = nil,
        instanceTag: String? = nil,
        windowID: UInt32? = nil,
        settingKey: String? = nil,
        settingValue: String? = nil,
        overrideState: CompanionState? = nil
    ) {
        self.action = action
        self.instanceID = instanceID
        self.instanceTag = instanceTag
        self.windowID = windowID
        self.settingKey = settingKey
        self.settingValue = settingValue
        self.overrideState = overrideState
    }
}

public struct AngyControlResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var message: String?
    public var windows: [AngyWindowRef]?
    public var instances: [AngyInstanceSnapshot]?
    public var settings: AngyGlobalSettingsSnapshot?

    public init(
        ok: Bool,
        message: String? = nil,
        windows: [AngyWindowRef]? = nil,
        instances: [AngyInstanceSnapshot]? = nil,
        settings: AngyGlobalSettingsSnapshot? = nil
    ) {
        self.ok = ok
        self.message = message
        self.windows = windows
        self.instances = instances
        self.settings = settings
    }
}

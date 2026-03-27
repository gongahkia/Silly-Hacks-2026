import AngyCore
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class WindowTracker {
    private let config: AppConfig
    private let trackingAXTimeout: Float = 0.05
    private var workspaceObservers: [NSObjectProtocol] = []
    private var axObserver: AXObserver?
    private var observedPID: pid_t?
    private var observedWindowElement: AXUIElement?
    private var cachedTrackedWindow: TrackedWindow?
    private var cachedAppContext: ObservedAppContext?

    var onWindowChange: (() -> Void)?

    init(config: AppConfig) {
        self.config = config
    }

    func startMonitoring() {
        guard workspaceObservers.isEmpty else {
            return
        }

        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didDeactivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ]

        workspaceObservers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleWorkspaceEvent()
                }
            }
        }

        refreshAccessibilityObserver()
    }

    func stopMonitoring() {
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
        clearAccessibilityObserver()
        cachedTrackedWindow = nil
        cachedAppContext = nil
    }

    func currentTrackedWindow() async -> TrackedWindow? {
        guard let snapshot = makeResolutionSnapshot() else {
            return nil
        }

        let trackedWindow = await Task.detached(priority: .userInitiated) {
            WindowTrackerResolver.resolve(snapshot)
        }.value

        guard currentFrontmostAppContext() == snapshot.appContext else {
            return nil
        }

        cachedAppContext = snapshot.appContext
        cachedTrackedWindow = trackedWindow
        return trackedWindow
    }

    private func makeResolutionSnapshot() -> WindowTrackingSnapshot? {
        guard let appContext = currentFrontmostAppContext() else {
            clearAccessibilityObserver()
            cachedTrackedWindow = nil
            cachedAppContext = nil
            return nil
        }

        refreshAccessibilityObserver(for: appContext.pid)

        let screens = NSScreen.screens.map {
            WindowTrackerScreen(name: $0.localizedName, frame: $0.frame)
        }

        return WindowTrackingSnapshot(
            config: config,
            appContext: appContext,
            trackingAXTimeout: trackingAXTimeout,
            screens: screens,
            observedWindowElement: observedWindowElement.map(AXElementHandle.init),
            cachedTrackedWindow: cachedTrackedWindow
        )
    }

    private func currentFrontmostAppContext() -> ObservedAppContext? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              config.targetBundleIDs.contains(bundleID) else {
            return nil
        }

        return ObservedAppContext(
            bundleID: bundleID,
            appName: app.localizedName ?? "Target App",
            pid: app.processIdentifier
        )
    }

    private func handleWorkspaceEvent() {
        cachedTrackedWindow = nil
        cachedAppContext = nil
        refreshAccessibilityObserver()
        onWindowChange?()
    }

    private func refreshAccessibilityObserver() {
        guard AXIsProcessTrusted(),
              let appContext = currentFrontmostAppContext() else {
            clearAccessibilityObserver()
            return
        }

        refreshAccessibilityObserver(for: appContext.pid)
    }

    private func refreshAccessibilityObserver(for pid: pid_t) {
        guard AXIsProcessTrusted() else {
            clearAccessibilityObserver()
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        setTrackingTimeoutIfPossible(for: appElement)

        if observedPID != pid || axObserver == nil {
            clearAccessibilityObserver()

            var observer: AXObserver?
            let result = AXObserverCreate(pid, Self.accessibilityCallback, &observer)
            guard result == .success, let observer else {
                return
            }

            axObserver = observer
            observedPID = pid

            CFRunLoopAddSource(
                CFRunLoopGetMain(),
                AXObserverGetRunLoopSource(observer),
                CFRunLoopMode.commonModes
            )

            let refcon = Unmanaged.passUnretained(self).toOpaque()
            addNotification(kAXFocusedWindowChangedNotification as CFString, to: appElement, refcon: refcon)
            addNotification(kAXMainWindowChangedNotification as CFString, to: appElement, refcon: refcon)
        }

        refreshFocusedWindowObserver(for: appElement)
    }

    private func refreshFocusedWindowObserver(for appElement: AXUIElement) {
        guard let focusedWindow = copyAttributeElement(
            from: appElement,
            attribute: kAXFocusedWindowAttribute as CFString
        ) else {
            clearFocusedWindowObserver()
            cachedTrackedWindow = nil
            return
        }

        setTrackingTimeoutIfPossible(for: focusedWindow)

        if let observedWindowElement, CFEqual(observedWindowElement, focusedWindow) {
            return
        }

        clearFocusedWindowObserver()
        observedWindowElement = focusedWindow
        cachedTrackedWindow = nil

        guard let axObserver else {
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let notifications: [CFString] = [
            kAXMovedNotification as CFString,
            kAXResizedNotification as CFString,
            kAXWindowMovedNotification as CFString,
            kAXWindowResizedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
            kAXWindowMiniaturizedNotification as CFString,
            kAXWindowDeminiaturizedNotification as CFString,
            kAXTitleChangedNotification as CFString
        ]

        notifications.forEach { notification in
            AXObserverAddNotification(axObserver, focusedWindow, notification, refcon)
        }
    }

    private func clearAccessibilityObserver() {
        clearFocusedWindowObserver()

        guard let axObserver, let observedPID else {
            self.axObserver = nil
            self.observedPID = nil
            return
        }

        let appElement = AXUIElementCreateApplication(observedPID)
        AXObserverRemoveNotification(axObserver, appElement, kAXFocusedWindowChangedNotification as CFString)
        AXObserverRemoveNotification(axObserver, appElement, kAXMainWindowChangedNotification as CFString)
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(axObserver),
            CFRunLoopMode.commonModes
        )

        self.axObserver = nil
        self.observedPID = nil
        self.cachedTrackedWindow = nil
    }

    private func clearFocusedWindowObserver() {
        guard let axObserver, let currentWindowElement = observedWindowElement else {
            observedWindowElement = nil
            return
        }

        let notifications: [CFString] = [
            kAXMovedNotification as CFString,
            kAXResizedNotification as CFString,
            kAXWindowMovedNotification as CFString,
            kAXWindowResizedNotification as CFString,
            kAXUIElementDestroyedNotification as CFString,
            kAXWindowMiniaturizedNotification as CFString,
            kAXWindowDeminiaturizedNotification as CFString,
            kAXTitleChangedNotification as CFString
        ]

        notifications.forEach { notification in
            AXObserverRemoveNotification(axObserver, currentWindowElement, notification)
        }

        observedWindowElement = nil
    }

    private func addNotification(_ notification: CFString, to element: AXUIElement, refcon: UnsafeMutableRawPointer) {
        guard let axObserver else {
            return
        }

        AXObserverAddNotification(axObserver, element, notification, refcon)
    }

    private func handleAccessibilityNotification(_ notification: String) {
        if (notification == kAXFocusedWindowChangedNotification as String ||
            notification == kAXMainWindowChangedNotification as String),
           let observedPID {
            refreshFocusedWindowObserver(for: AXUIElementCreateApplication(observedPID))
        } else if notification == kAXUIElementDestroyedNotification as String ||
                    notification == kAXWindowMiniaturizedNotification as String {
            cachedTrackedWindow = nil
        }

        cachedTrackedWindow = nil
        onWindowChange?()
    }

    private func copyAttributeElement(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func setTrackingTimeoutIfPossible(for element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, trackingAXTimeout)
    }

    private static let accessibilityCallback: AXObserverCallback = { _, _, notification, refcon in
        guard let refcon else {
            return
        }

        let tracker = Unmanaged<WindowTracker>.fromOpaque(refcon).takeUnretainedValue()
        let notificationName = notification as String

        Task { @MainActor in
            tracker.handleAccessibilityNotification(notificationName)
        }
    }
}

private enum WindowTrackerResolver {
    static func resolve(_ snapshot: WindowTrackingSnapshot) -> TrackedWindow? {
        let appContext = snapshot.appContext
        let cachedTrackedWindow = snapshot.cachedTrackedWindow
        let focusedHints = snapshot.observedWindowElement
            .flatMap { focusedWindowHints(from: $0.element, trackingAXTimeout: snapshot.trackingAXTimeout) }
            ?? accessibilityHints(pid: appContext.pid, trackingAXTimeout: snapshot.trackingAXTimeout)

        if let focusedHints,
           let bounds = focusedHints.bounds,
           focusedHints.isMinimized != true {
            let windowID = cachedWindowID(from: cachedTrackedWindow, appContext: appContext)
                ?? resolvedWindowID(for: appContext.pid, hints: focusedHints, config: snapshot.config)
                ?? 0
            let appKitFrame = convertToAppKitCoordinates(cgBounds: bounds, screens: snapshot.screens)
            return TrackedWindow(
                bundleID: appContext.bundleID,
                appName: appContext.appName,
                windowID: windowID,
                frame: appKitFrame,
                screenID: screenID(for: appKitFrame, screens: snapshot.screens),
                isVisible: true,
                title: focusedHints.title ?? cachedTrackedWindow?.title
            )
        }

        if let cachedTrackedWindow,
           cachedTrackedWindow.windowID != 0,
           let matchedWindow = visibleWindow(
                for: cachedTrackedWindow.windowID,
                expectedPID: appContext.pid,
                config: snapshot.config
           ) {
            let appKitFrame = convertToAppKitCoordinates(cgBounds: matchedWindow.bounds, screens: snapshot.screens)
            return TrackedWindow(
                bundleID: appContext.bundleID,
                appName: appContext.appName,
                windowID: matchedWindow.windowID,
                frame: appKitFrame,
                screenID: screenID(for: appKitFrame, screens: snapshot.screens),
                isVisible: true,
                title: matchedWindow.title ?? cachedTrackedWindow.title
            )
        }

        let candidates = orderedVisibleWindows(for: appContext.pid, config: snapshot.config)
        guard let matchedWindow = bestMatch(from: candidates, hints: focusedHints) else {
            return nil
        }

        let appKitFrame = convertToAppKitCoordinates(cgBounds: matchedWindow.bounds, screens: snapshot.screens)
        return TrackedWindow(
            bundleID: appContext.bundleID,
            appName: appContext.appName,
            windowID: matchedWindow.windowID,
            frame: appKitFrame,
            screenID: screenID(for: appKitFrame, screens: snapshot.screens),
            isVisible: true,
            title: matchedWindow.title
        )
    }

    private static func cachedWindowID(
        from trackedWindow: TrackedWindow?,
        appContext: ObservedAppContext
    ) -> UInt32? {
        guard let trackedWindow,
              trackedWindow.bundleID == appContext.bundleID,
              trackedWindow.windowID != 0 else {
            return nil
        }

        return trackedWindow.windowID
    }

    private static func resolvedWindowID(
        for pid: pid_t,
        hints: FocusedWindowHints,
        config: AppConfig
    ) -> UInt32? {
        let candidates = orderedVisibleWindows(for: pid, config: config)
        return bestMatch(from: candidates, hints: hints)?.windowID
    }

    private static func orderedVisibleWindows(for pid: pid_t, config: AppConfig) -> [WindowCandidate] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return list.compactMap { info in
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                ?? Int32(info[kCGWindowOwnerPID as String] as? Int ?? -1)
            guard ownerPID == pid else {
                return nil
            }

            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard layer == 0, alpha > 0.01 else {
                return nil
            }

            guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  bounds.width > 240,
                  bounds.height > 140 else {
                return nil
            }

            let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
            guard config.targetOwnerNames.contains(ownerName) else {
                return nil
            }

            let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                ?? UInt32(info[kCGWindowNumber as String] as? Int ?? 0)
            let title = info[kCGWindowName as String] as? String
            return WindowCandidate(windowID: windowID, bounds: bounds, title: title)
        }
    }

    private static func visibleWindow(
        for windowID: UInt32,
        expectedPID: pid_t,
        config: AppConfig
    ) -> WindowCandidate? {
        let options: CGWindowListOption = [.optionIncludingWindow]
        guard let list = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]],
              let info = list.first else {
            return nil
        }

        let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            ?? Int32(info[kCGWindowOwnerPID as String] as? Int ?? -1)
        guard ownerPID == expectedPID else {
            return nil
        }

        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
        guard layer == 0, alpha > 0.01 else {
            return nil
        }

        guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary),
              bounds.width > 0,
              bounds.height > 0 else {
            return nil
        }

        let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
        guard config.targetOwnerNames.contains(ownerName) else {
            return nil
        }

        let title = info[kCGWindowName as String] as? String
        return WindowCandidate(windowID: windowID, bounds: bounds, title: title)
    }

    private static func bestMatch(
        from candidates: [WindowCandidate],
        hints: FocusedWindowHints?
    ) -> WindowCandidate? {
        guard !candidates.isEmpty else {
            return nil
        }

        if let title = hints?.title?.lowercased(),
           let titleMatch = candidates.first(where: { ($0.title ?? "").lowercased() == title }) {
            return titleMatch
        }

        if let hintBounds = hints?.bounds {
            let bestByOverlap = candidates.max { lhs, rhs in
                overlapScore(lhs.bounds, hintBounds) < overlapScore(rhs.bounds, hintBounds)
            }

            if let bestByOverlap, overlapScore(bestByOverlap.bounds, hintBounds) > 0.35 {
                return bestByOverlap
            }
        }

        return candidates.first
    }

    private static func accessibilityHints(pid: pid_t, trackingAXTimeout: Float) -> FocusedWindowHints? {
        guard AXIsProcessTrusted() else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid)
        setTrackingTimeout(trackingAXTimeout, for: appElement)
        guard let windowElement = copyAttributeElement(
            from: appElement,
            attribute: kAXFocusedWindowAttribute as CFString
        ) else {
            return nil
        }

        setTrackingTimeout(trackingAXTimeout, for: windowElement)
        return focusedWindowHints(from: windowElement, trackingAXTimeout: trackingAXTimeout)
    }

    private static func focusedWindowHints(
        from windowElement: AXUIElement,
        trackingAXTimeout: Float
    ) -> FocusedWindowHints? {
        setTrackingTimeout(trackingAXTimeout, for: windowElement)

        let attributes: [CFString] = [
            kAXTitleAttribute as CFString,
            kAXPositionAttribute as CFString,
            kAXSizeAttribute as CFString,
            kAXMinimizedAttribute as CFString
        ]

        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            windowElement,
            attributes as CFArray,
            [],
            &values
        )

        if result == .success,
           let values = values as? [Any] {
            let title = values[safe: 0] as? String
            let position = point(from: values[safe: 1])
            let size = size(from: values[safe: 2])
            let isMinimized = bool(from: values[safe: 3])

            let bounds = position.flatMap { position in
                size.map { CGRect(origin: position, size: $0) }
            }

            return FocusedWindowHints(title: title, bounds: bounds, isMinimized: isMinimized)
        }

        let title = copyAttributeString(from: windowElement, attribute: kAXTitleAttribute as CFString)
        let position = copyCGPoint(from: windowElement, attribute: kAXPositionAttribute as CFString)
        let size = copyCGSize(from: windowElement, attribute: kAXSizeAttribute as CFString)
        let isMinimized = copyAttributeBool(from: windowElement, attribute: kAXMinimizedAttribute as CFString)

        let bounds = position.flatMap { position in
            size.map { CGRect(origin: position, size: $0) }
        }

        return FocusedWindowHints(title: title, bounds: bounds, isMinimized: isMinimized)
    }

    private static func convertToAppKitCoordinates(
        cgBounds: CGRect,
        screens: [WindowTrackerScreen]
    ) -> CGRect {
        let maxScreenY = screens.map(\.frame.maxY).max() ?? 0
        return CGRect(
            x: cgBounds.origin.x,
            y: maxScreenY - cgBounds.origin.y - cgBounds.height,
            width: cgBounds.width,
            height: cgBounds.height
        )
    }

    private static func screenID(
        for frame: CGRect,
        screens: [WindowTrackerScreen]
    ) -> String? {
        screens.first(where: { $0.frame.intersects(frame) })?.name
    }

    private static func overlapScore(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, lhs.width > 0, lhs.height > 0 else {
            return 0
        }
        return (intersection.width * intersection.height) / (lhs.width * lhs.height)
    }

    private static func setTrackingTimeout(_ timeout: Float, for element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, timeout)
    }

    private static func copyAttributeElement(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private static func copyAttributeString(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            return nil
        }
        return value as? String
    }

    private static func copyCGPoint(from element: AXUIElement, attribute: CFString) -> CGPoint? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else {
            return nil
        }
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let castValue = unsafeBitCast(value, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetValue(castValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private static func copyCGSize(from element: AXUIElement, attribute: CFString) -> CGSize? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else {
            return nil
        }
        guard CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let castValue = unsafeBitCast(value, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetValue(castValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private static func copyAttributeBool(from element: AXUIElement, attribute: CFString) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else {
            return nil
        }

        return bool(from: value)
    }

    private static func point(from value: Any?) -> CGPoint? {
        guard let value else {
            return nil
        }
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else {
            return nil
        }

        let castValue = unsafeBitCast(value as CFTypeRef, to: AXValue.self)
        var point = CGPoint.zero
        guard AXValueGetValue(castValue, .cgPoint, &point) else {
            return nil
        }
        return point
    }

    private static func size(from value: Any?) -> CGSize? {
        guard let value else {
            return nil
        }
        guard CFGetTypeID(value as CFTypeRef) == AXValueGetTypeID() else {
            return nil
        }

        let castValue = unsafeBitCast(value as CFTypeRef, to: AXValue.self)
        var size = CGSize.zero
        guard AXValueGetValue(castValue, .cgSize, &size) else {
            return nil
        }
        return size
    }

    private static func bool(from value: Any?) -> Bool? {
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }
}

private struct WindowTrackingSnapshot: Sendable {
    let config: AppConfig
    let appContext: ObservedAppContext
    let trackingAXTimeout: Float
    let screens: [WindowTrackerScreen]
    let observedWindowElement: AXElementHandle?
    let cachedTrackedWindow: TrackedWindow?
}

private struct AXElementHandle: @unchecked Sendable {
    let element: AXUIElement
}

private struct WindowTrackerScreen: Sendable {
    let name: String
    let frame: CGRect
}

private struct WindowCandidate: Sendable {
    let windowID: UInt32
    let bounds: CGRect
    let title: String?
}

private struct FocusedWindowHints: Sendable {
    let title: String?
    let bounds: CGRect?
    let isMinimized: Bool?
}

private struct ObservedAppContext: Sendable, Equatable {
    let bundleID: String
    let appName: String
    let pid: pid_t
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

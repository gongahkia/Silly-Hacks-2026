import AngyCore
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

@MainActor
final class WindowTracker {
    private let config: AppConfig

    init(config: AppConfig) {
        self.config = config
    }

    func currentTrackedWindow() -> TrackedWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        guard let bundleID = app.bundleIdentifier, config.targetBundleIDs.contains(bundleID) else {
            return nil
        }

        let appName = app.localizedName ?? "Codex"
        let pid = app.processIdentifier
        let focusedHints = accessibilityHints(pid: pid)
        let candidates = orderedVisibleWindows(for: pid)
        guard let matchedWindow = bestMatch(from: candidates, hints: focusedHints) else {
            return nil
        }

        let appKitFrame = convertToAppKitCoordinates(cgBounds: matchedWindow.bounds)
        let screenID = NSScreen.screens.first(where: { $0.frame.intersects(appKitFrame) })?.localizedName

        return TrackedWindow(
            bundleID: bundleID,
            appName: appName,
            windowID: matchedWindow.windowID,
            frame: appKitFrame,
            screenID: screenID,
            isVisible: true,
            title: matchedWindow.title ?? focusedHints?.title
        )
    }

    private func orderedVisibleWindows(for pid: pid_t) -> [WindowCandidate] {
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

    private func bestMatch(
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

    private func accessibilityHints(pid: pid_t) -> FocusedWindowHints? {
        guard AXIsProcessTrusted() else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(pid)
        guard let windowElement = copyAttributeElement(
            from: appElement,
            attribute: kAXFocusedWindowAttribute as CFString
        ) else {
            return nil
        }

        let title = copyAttributeString(from: windowElement, attribute: kAXTitleAttribute as CFString)
        let position = copyCGPoint(from: windowElement, attribute: kAXPositionAttribute as CFString)
        let size = copyCGSize(from: windowElement, attribute: kAXSizeAttribute as CFString)

        let bounds: CGRect?
        if let position, let size {
            bounds = CGRect(origin: position, size: size)
        } else {
            bounds = nil
        }

        return FocusedWindowHints(title: title, bounds: bounds)
    }

    private func copyAttributeElement(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func copyAttributeString(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            return nil
        }
        return value as? String
    }

    private func copyCGPoint(from element: AXUIElement, attribute: CFString) -> CGPoint? {
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

    private func copyCGSize(from element: AXUIElement, attribute: CFString) -> CGSize? {
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

    private func overlapScore(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, lhs.width > 0, lhs.height > 0 else {
            return 0
        }
        return (intersection.width * intersection.height) / (lhs.width * lhs.height)
    }

    private func convertToAppKitCoordinates(cgBounds: CGRect) -> CGRect {
        let maxScreenY = NSScreen.screens.map(\.frame.maxY).max() ?? 0
        return CGRect(
            x: cgBounds.origin.x,
            y: maxScreenY - cgBounds.origin.y - cgBounds.height,
            width: cgBounds.width,
            height: cgBounds.height
        )
    }
}

private struct WindowCandidate {
    let windowID: UInt32
    let bounds: CGRect
    let title: String?
}

private struct FocusedWindowHints {
    let title: String?
    let bounds: CGRect?
}

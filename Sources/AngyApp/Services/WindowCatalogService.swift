import AngyCore
import AppKit
import CoreGraphics
import Foundation

struct WindowCatalogService {
    func visibleWindows() -> [TrackedWindow] {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focusedWindowID = focusedFrontmostWindowID(frontmostPID: frontmostPID)

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        return list.compactMap { info in
            trackedWindow(from: info, frontmostPID: frontmostPID, focusedWindowID: focusedWindowID)
        }
    }

    func window(windowID: UInt32) -> TrackedWindow? {
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let focusedWindowID = focusedFrontmostWindowID(frontmostPID: frontmostPID)

        let options: CGWindowListOption = [.optionIncludingWindow]
        guard let list = CGWindowListCopyWindowInfo(options, windowID) as? [[String: Any]] else {
            return nil
        }

        return list.compactMap {
            trackedWindow(from: $0, frontmostPID: frontmostPID, focusedWindowID: focusedWindowID)
        }.first(where: { $0.windowID == windowID })
    }

    func frontmostWindow() -> TrackedWindow? {
        visibleWindows().first(where: \.isFocused)
    }

    private func trackedWindow(
        from info: [String: Any],
        frontmostPID: pid_t?,
        focusedWindowID: UInt32?
    ) -> TrackedWindow? {
        let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
            ?? Int32(info[kCGWindowOwnerPID as String] as? Int ?? -1)
        guard ownerPID > 0, ownerPID != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }

        let layer = info[kCGWindowLayer as String] as? Int ?? 0
        let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
        guard layer == 0, alpha > 0.01 else {
            return nil
        }

        guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let cgBounds = CGRect(dictionaryRepresentation: boundsDictionary),
              cgBounds.width > 240,
              cgBounds.height > 140 else {
            return nil
        }

        guard let app = NSRunningApplication(processIdentifier: ownerPID),
              !app.isTerminated else {
            return nil
        }

        let bundleID = app.bundleIdentifier ?? "unknown.bundle"
        let ownerName = (info[kCGWindowOwnerName as String] as? String)
            ?? app.localizedName
            ?? "Unknown App"
        let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
            ?? UInt32(info[kCGWindowNumber as String] as? Int ?? 0)
        let title = info[kCGWindowName as String] as? String

        let appKitFrame = convertToAppKitCoordinates(cgBounds: cgBounds)

        return TrackedWindow(
            bundleID: bundleID,
            appName: ownerName,
            windowID: windowID,
            frame: appKitFrame,
            screenID: screenID(for: appKitFrame),
            isVisible: true,
            title: title,
            isFocused: ownerPID == frontmostPID && windowID == focusedWindowID
        )
    }

    private func focusedFrontmostWindowID(frontmostPID: pid_t?) -> UInt32? {
        guard let frontmostPID else {
            return nil
        }

        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for info in list {
            let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
                ?? Int32(info[kCGWindowOwnerPID as String] as? Int ?? -1)
            guard ownerPID == frontmostPID else {
                continue
            }

            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard layer == 0, alpha > 0.01 else {
                continue
            }

            let windowID = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value
                ?? UInt32(info[kCGWindowNumber as String] as? Int ?? 0)
            guard windowID != 0 else {
                continue
            }

            return windowID
        }

        return nil
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

    private func screenID(for frame: CGRect) -> String? {
        NSScreen.screens.first(where: { $0.frame.intersects(frame) })?.localizedName
    }
}

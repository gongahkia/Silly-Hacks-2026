import AngyCore
import AppKit
import ApplicationServices
import Foundation

final class AccessibilityTextExtractor {
    private let maxDepth = 6
    private let maxNodes = 450

    func extractText(forBundleIdentifier bundleIdentifier: String, appName: String) -> String? {
        guard AXIsProcessTrusted() else {
            return nil
        }

        guard let runningApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first ??
                NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == appName }) else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(runningApp.processIdentifier)
        guard let windowElement = copyElement(from: appElement, attribute: kAXFocusedWindowAttribute as CFString) else {
            return nil
        }

        var remainingBudget = maxNodes
        var collected: [String] = []
        collectText(from: windowElement, depth: 0, remainingBudget: &remainingBudget, collected: &collected)

        let joined = collected.joined(separator: "\n")
        let normalized = TextNormalizer.normalize(joined)
        return normalized.isEmpty ? nil : joined
    }

    private func collectText(
        from element: AXUIElement,
        depth: Int,
        remainingBudget: inout Int,
        collected: inout [String]
    ) {
        guard depth <= maxDepth, remainingBudget > 0 else {
            return
        }

        remainingBudget -= 1

        let stringAttributes: [CFString] = [
            kAXTitleAttribute as CFString,
            kAXValueAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXHelpAttribute as CFString
        ]

        for attribute in stringAttributes {
            guard let text = copyString(from: element, attribute: attribute) else { continue }
            let normalized = TextNormalizer.normalizeLine(text)
            guard !normalized.isEmpty else { continue }
            collected.append(text)
        }

        let childAttributes: [CFString] = [
            kAXChildrenAttribute as CFString,
            kAXVisibleChildrenAttribute as CFString,
            kAXRowsAttribute as CFString,
            kAXContentsAttribute as CFString
        ]

        for attribute in childAttributes {
            guard let children = copyElements(from: element, attribute: attribute) else { continue }
            for child in children {
                collectText(from: child, depth: depth + 1, remainingBudget: &remainingBudget, collected: &collected)
            }
        }
    }

    private func copyElement(from element: AXUIElement, attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else {
            return nil
        }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func copyString(from element: AXUIElement, attribute: CFString) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else {
            return nil
        }

        if let string = value as? String {
            return string
        }

        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }

        return nil
    }

    private func copyElements(from element: AXUIElement, attribute: CFString) -> [AXUIElement]? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else {
            return nil
        }

        guard let rawChildren = value as? [Any] else {
            return nil
        }

        return rawChildren.compactMap { child in
            guard CFGetTypeID(child as CFTypeRef) == AXUIElementGetTypeID() else {
                return nil
            }
            return unsafeBitCast(child as CFTypeRef, to: AXUIElement.self)
        }
    }
}

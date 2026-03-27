import AngyCore
import AppKit
import ApplicationServices
import Foundation

final class AccessibilityTextExtractor {
    private let maxDepth = 6
    private let maxNodes = 450

    func extractText(
        forBundleIdentifier bundleIdentifier: String,
        appName: String,
        windowTitle: String? = nil
    ) -> String? {
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
        return Self.sanitizedExtractedText(from: joined, windowTitle: windowTitle)
    }

    static func sanitizedExtractedText(from rawText: String, windowTitle: String?) -> String? {
        let lines = TextNormalizer.splitLines(in: rawText)
        guard !lines.isEmpty else {
            return nil
        }

        let chromeCandidates = chromeTitleCandidates(from: windowTitle)
        var seen = Set<String>()
        let filteredLines = lines.filter { line in
            let normalized = TextNormalizer.normalizeLine(line)
            guard !normalized.isEmpty else {
                return false
            }

            guard !isLikelyWindowChrome(normalizedLine: normalized, chromeCandidates: chromeCandidates) else {
                return false
            }

            guard !isLikelyAccessibilityBoilerplate(normalizedLine: normalized) else {
                return false
            }

            return seen.insert(normalized).inserted
        }

        let joined = filteredLines.joined(separator: "\n")
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
            kAXValueAttribute as CFString
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

    private static func chromeTitleCandidates(from windowTitle: String?) -> Set<String> {
        guard let windowTitle else {
            return []
        }

        let normalizedTitle = TextNormalizer.normalizeLine(windowTitle)
        guard !normalizedTitle.isEmpty else {
            return []
        }

        var candidates: Set<String> = [normalizedTitle]

        let separators = [",", " - ", " — ", " – ", " · "]
        for separator in separators {
            if let range = normalizedTitle.range(of: separator) {
                let prefix = String(normalizedTitle[..<range.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if prefix.count >= 4 {
                    candidates.insert(prefix)
                }
            }
        }

        return candidates
    }

    private static func isLikelyWindowChrome(
        normalizedLine: String,
        chromeCandidates: Set<String>
    ) -> Bool {
        for candidate in chromeCandidates {
            if normalizedLine == candidate {
                return true
            }

            if normalizedLine.count >= 8 && candidate.contains(normalizedLine) {
                return true
            }

            if candidate.count >= 8 && normalizedLine.contains(candidate) {
                return true
            }
        }

        return false
    }

    private static func isLikelyAccessibilityBoilerplate(normalizedLine: String) -> Bool {
        let boilerplatePhrases = [
            "activate to focus this workspace",
            "drag to reorder",
            "move up and move down actions"
        ]

        return boilerplatePhrases.contains { normalizedLine.contains($0) }
    }
}

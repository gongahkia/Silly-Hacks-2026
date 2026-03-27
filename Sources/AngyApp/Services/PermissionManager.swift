import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct PermissionStatus: Equatable, Sendable {
    let accessibility: Bool
    let screenRecording: Bool
}

@MainActor
final class PermissionManager {
    private let onboardingKey = "angy.didShowPermissionOnboarding"

    func status() -> PermissionStatus {
        PermissionStatus(
            accessibility: AXIsProcessTrusted(),
            screenRecording: CGPreflightScreenCaptureAccess()
        )
    }

    func requestMissingPermissions() {
        let currentStatus = status()

        if !currentStatus.accessibility {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        if !currentStatus.screenRecording {
            _ = CGRequestScreenCaptureAccess()
        }
    }

    func presentOnboardingIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: onboardingKey) else { return }
        let currentStatus = status()
        guard !currentStatus.accessibility || !currentStatus.screenRecording else { return }

        let missingPermissions = missingPermissionDescriptions(for: currentStatus)
            .joined(separator: "\n• ")

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Angy needs macOS permissions"
        alert.informativeText = """
        Angy can only analyze the active Codex, Ghostty, or cmux window when the following permissions are enabled:

        • \(missingPermissions)

        Accessibility lets Angy inspect visible UI text.
        Screen Recording lets Angy OCR the window when Accessibility text is unavailable.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            openRelevantSettings()
        }

        UserDefaults.standard.set(true, forKey: onboardingKey)
    }

    private func missingPermissionDescriptions(for status: PermissionStatus) -> [String] {
        var descriptions: [String] = []

        if !status.accessibility {
            descriptions.append("Accessibility")
        }

        if !status.screenRecording {
            descriptions.append("Screen Recording")
        }

        return descriptions
    }

    private func openRelevantSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ]

        for urlString in urls {
            guard let url = URL(string: urlString) else { continue }
            NSWorkspace.shared.open(url)
        }
    }
}

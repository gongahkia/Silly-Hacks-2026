import AngyCore
import Foundation

enum HateMailWriterError: LocalizedError {
    case featureDisabled
    case coolingDown(remaining: TimeInterval)
    case desktopUnavailable
    case folderCreationFailed(Error)
    case writeFailed(Error)

    var errorDescription: String? {
        switch self {
        case .featureDisabled:
            return "Hate mail is disabled."
        case .coolingDown(let remaining):
            return "This Angy is still cooling down. Try again in \(Self.formattedDuration(remaining))."
        case .desktopUnavailable:
            return "The Desktop folder is unavailable."
        case .folderCreationFailed(let error):
            return "Could not create the Angy Hate Mail folder: \(error.localizedDescription)"
        case .writeFailed(let error):
            return "Could not write the hate-mail file: \(error.localizedDescription)"
        }
    }

    private static func formattedDuration(_ remaining: TimeInterval) -> String {
        let roundedSeconds = max(1, Int(ceil(remaining)))
        let minutes = roundedSeconds / 60
        let seconds = roundedSeconds % 60

        if minutes > 0, seconds > 0 {
            return "\(minutes)m \(seconds)s"
        }

        if minutes > 0 {
            return "\(minutes)m"
        }

        return "\(seconds)s"
    }
}

actor HateMailWriter {
    private var lastWriteDates: [AngyInstanceID: Date] = [:]
    private let fileManager = FileManager.default
    private let baseDirectoryProvider: @Sendable () -> URL?

    init(baseDirectoryProvider: @escaping @Sendable () -> URL? = {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }) {
        self.baseDirectoryProvider = baseDirectoryProvider
    }

    func writeMail(
        for snapshot: AngyInstanceSnapshot,
        config: AppConfig,
        enabled: Bool,
        force: Bool = false
    ) throws -> URL {
        guard enabled else {
            throw HateMailWriterError.featureDisabled
        }

        let now = Date()
        if let lastWriteDate = lastWriteDates[snapshot.id],
           !force {
            let elapsed = now.timeIntervalSince(lastWriteDate)
            if elapsed < config.hateMailCooldown {
                throw HateMailWriterError.coolingDown(remaining: config.hateMailCooldown - elapsed)
            }
        }

        guard let desktopURL = baseDirectoryProvider() else {
            throw HateMailWriterError.desktopUnavailable
        }

        let folderURL = desktopURL.appendingPathComponent(config.hateMailOutputFolderName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            throw HateMailWriterError.folderCreationFailed(error)
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let timestamp = formatter.string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        let label = sanitizedLabel(snapshot.tag ?? "Primary")
        let fileURL = folderURL.appendingPathComponent("Angy-\(label)-\(timestamp).txt", isDirectory: false)
        let content = content(for: snapshot, timestamp: now)

        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            lastWriteDates[snapshot.id] = now
            return fileURL
        } catch {
            throw HateMailWriterError.writeFailed(error)
        }
    }

    private func sanitizedLabel(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "#-_"))
        return value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.reduce(into: "") {
            $0.append($1)
        }
    }

    private func content(for snapshot: AngyInstanceSnapshot, timestamp: Date) -> String {
        let label = snapshot.tag ?? "Primary"
        let targetDescription: String
        if let target = snapshot.target {
            let title = target.title?.isEmpty == false ? target.title! : "Untitled Window"
            targetDescription = "\(target.appName) / \(title)"
        } else {
            targetDescription = "Detached Window"
        }

        let triggerSummary = snapshot.matchedTriggers.isEmpty
            ? "No specific trigger words survived the rage."
            : "Triggers: \(snapshot.matchedTriggers.joined(separator: ", "))"
        let quip = snapshot.quip ?? defaultQuip(for: snapshot.emotion)

        return """
        Angy \(label)
        Timestamp: \(timestamp)
        Target: \(targetDescription)
        Emotion: \(snapshot.emotion.rawValue)
        Activity: \(snapshot.activity.rawValue)
        Rage: \(String(format: "%.1f", snapshot.angerScore))

        \(quip)

        \(triggerSummary)

        This file was generated locally by Angy after sustained critical rage.
        """
    }

    private func defaultQuip(for emotion: CompanionState) -> String {
        switch emotion {
        case .calm:
            return "I am disappointed that this did not escalate more."
        case .curious:
            return "Something smells off and I have notes."
        case .annoyed:
            return "I have begun documenting your crimes."
        case .furious:
            return "This machine has witnessed too much."
        }
    }
}

import AngyCore
import Foundation

struct CodexParsedMessage: Equatable {
    let timestamp: Date?
    let message: String
}

actor CodexRolloutTextSource {
    private let sessionsDirectory: URL
    private let fileManager: FileManager
    private let debugEnabled: Bool
    private let rescanInterval: TimeInterval = 0.5

    private var activeFileURL: URL?
    private var fileOffset: UInt64 = 0
    private var carryoverLine = ""
    private var latestMessage: CodexParsedMessage?
    private var lastDeliveredKey: String?
    private var lastRescanDate: Date = .distantPast
    private var cachedLatestFileURL: URL?

    init(
        codexHomeDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.sessionsDirectory = codexHomeDirectory.appendingPathComponent("sessions", isDirectory: true)
        self.fileManager = fileManager
        self.debugEnabled = ProcessInfo.processInfo.environment["ANGY_DEBUG"] == "1"
    }

    func nextObservation(
        minimumMeaningfulTextLength: Int,
        now: Date = Date()
    ) -> TextObservation? {
        refreshState(now: now)

        guard let latestMessage else {
            return nil
        }

        let normalized = TextNormalizer.normalize(latestMessage.message)
        guard normalized.count >= minimumMeaningfulTextLength else {
            return nil
        }

        let timestamp = latestMessage.timestamp ?? now
        let key = "\(timestamp.timeIntervalSince1970)|\(normalized)"
        guard key != lastDeliveredKey else {
            return nil
        }

        lastDeliveredKey = key

        if debugEnabled {
            let activeFilePath = activeFileURL?.path ?? "-"
            log(
                "codex_sessions read file=\(activeFilePath) chars=\(latestMessage.message.count) preview=\(previewText(latestMessage.message))"
            )
        }

        return TextObservation(
            timestamp: timestamp,
            source: .codexOutput,
            rawText: latestMessage.message,
            normalizedText: normalized,
            confidence: 1
        )
    }

    private func refreshState(now: Date) {
        let shouldRescan = cachedLatestFileURL == nil || now.timeIntervalSince(lastRescanDate) >= rescanInterval
        if shouldRescan {
            cachedLatestFileURL = latestRolloutFileURL()
            lastRescanDate = now
        }

        guard let latestFileURL = cachedLatestFileURL else {
            return
        }

        if activeFileURL != latestFileURL {
            activeFileURL = latestFileURL
            fileOffset = 0
            carryoverLine = ""
        }

        consumeLatestLines(from: latestFileURL)
    }

    private func latestRolloutFileURL() -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: sessionsDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var latestPath: String?
        var latestURL: URL?

        for case let fileURL as URL in enumerator {
            guard fileURL.lastPathComponent.hasPrefix("rollout-"),
                  fileURL.pathExtension == "jsonl" else {
                continue
            }

            let path = fileURL.path
            if latestPath == nil || path > latestPath! {
                latestPath = path
                latestURL = fileURL
            }
        }

        return latestURL
    }

    private func consumeLatestLines(from fileURL: URL) {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else {
            return
        }
        defer { try? fileHandle.close() }

        if let fileSize = fileSize(for: fileURL),
           fileSize < fileOffset {
            fileOffset = 0
            carryoverLine = ""
        }

        do {
            try fileHandle.seek(toOffset: fileOffset)
            let data = try fileHandle.readToEnd() ?? Data()
            guard !data.isEmpty else {
                return
            }

            fileOffset += UInt64(data.count)
            appendDataToLineBuffer(data)
        } catch {
            return
        }
    }

    private func fileSize(for fileURL: URL) -> UInt64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
              let sizeNumber = attributes[.size] as? NSNumber else {
            return nil
        }

        return sizeNumber.uint64Value
    }

    private func appendDataToLineBuffer(_ data: Data) {
        let chunk = String(decoding: data, as: UTF8.self)
        let combined = carryoverLine + chunk
        var lines = combined.components(separatedBy: .newlines)

        if combined.hasSuffix("\n") {
            carryoverLine = ""
        } else {
            carryoverLine = lines.popLast() ?? ""
        }

        for line in lines where !line.isEmpty {
            if let parsed = Self.parseMessage(fromJSONLine: line) {
                latestMessage = parsed
            }
        }
    }

    static func parseMessage(fromJSONLine line: String) -> CodexParsedMessage? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rootType = object["type"] as? String else {
            return nil
        }

        let timestamp = parseTimestamp(from: object["timestamp"] as? String)

        if rootType == "event_msg",
           let payload = object["payload"] as? [String: Any],
           let payloadType = payload["type"] as? String {
            if payloadType == "agent_message",
               let message = payload["message"] as? String {
                return CodexParsedMessage(timestamp: timestamp, message: message)
            }

            if payloadType == "task_complete",
               let message = payload["last_agent_message"] as? String {
                return CodexParsedMessage(timestamp: timestamp, message: message)
            }
        }

        if rootType == "response_item",
           let payload = object["payload"] as? [String: Any],
           let payloadType = payload["type"] as? String,
           payloadType == "message",
           let role = payload["role"] as? String,
           role == "assistant",
           let content = payload["content"] as? [[String: Any]] {
            let textParts = content.compactMap { contentPart -> String? in
                guard let type = contentPart["type"] as? String, type == "output_text" else {
                    return nil
                }
                return contentPart["text"] as? String
            }
            let combinedText = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !combinedText.isEmpty {
                return CodexParsedMessage(timestamp: timestamp, message: combinedText)
            }
        }

        return nil
    }

    private static func parseTimestamp(from rawValue: String?) -> Date? {
        guard let rawValue, !rawValue.isEmpty else {
            return nil
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let timestamp = formatter.date(from: rawValue) {
            return timestamp
        }

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]
        return fallbackFormatter.date(from: rawValue)
    }

    private func log(_ message: String) {
        print("[AngyDebug] \(message)")
    }

    private func previewText(_ text: String) -> String {
        let compact = text
            .replacingOccurrences(of: "\n", with: " | ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if compact.count <= 220 {
            return compact
        }

        let endIndex = compact.index(compact.startIndex, offsetBy: 220)
        return String(compact[..<endIndex]) + "..."
    }
}

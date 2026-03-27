import Foundation

/// Maintains a time-bounded stream of visible window text and exposes a
/// deduplicated transcript for downstream sentiment and activity analysis.
public final class RollingTextBuffer {
    private let windowDuration: TimeInterval

    public private(set) var observations: [TextObservation]

    public init(windowDuration: TimeInterval) {
        self.windowDuration = windowDuration
        self.observations = []
    }

    public func append(_ observation: TextObservation, now: Date = Date()) {
        observations.append(observation)
        prune(now: now)
    }

    public func prune(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-windowDuration)
        observations.removeAll { $0.timestamp < cutoff }
    }

    public func clear() {
        observations.removeAll()
    }

    /// Returns recent visible text as a rolling transcript, keeping only the
    /// first occurrence of each normalized line within the active window.
    public func recentTranscript(now: Date = Date()) -> String {
        prune(now: now)

        var seen = Set<String>()
        var lines: [String] = []

        for observation in observations.sorted(by: { $0.timestamp < $1.timestamp }) {
            for line in TextNormalizer.splitLines(in: observation.rawText) {
                let normalizedLine = TextNormalizer.normalizeLine(line)
                guard !normalizedLine.isEmpty else { continue }
                guard seen.insert(normalizedLine).inserted else { continue }
                lines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        return lines.joined(separator: "\n")
    }

    public func repeatedLineCounts(now: Date = Date()) -> [String: Int] {
        prune(now: now)

        var counts: [String: Int] = [:]
        for observation in observations {
            for line in TextNormalizer.splitLines(in: observation.normalizedText) {
                counts[line, default: 0] += 1
            }
        }

        return counts
    }
}

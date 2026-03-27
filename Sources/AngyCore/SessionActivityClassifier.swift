import Foundation

public struct SessionActivityClassifier: Sendable {
    private let celebratingTokens: Set<String> = [
        "fixed", "passed", "success", "solved", "resolved", "working"
    ]
    private let proseStopWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "because", "but", "by",
        "can", "do", "for", "from", "how", "if", "in", "into", "is", "it",
        "just", "of", "on", "or", "should", "that", "the", "their", "then",
        "there", "this", "to", "was", "what", "when", "where", "which", "while",
        "with", "you", "your"
    ]
    private let codeKeywords: Set<String> = [
        "class", "const", "else", "enum", "false", "func", "if", "import",
        "let", "nil", "null", "public", "private", "return", "self", "static",
        "struct", "true", "type", "var"
    ]

    public init() {}

    public func classify(
        observations: [TextObservation],
        sentimentResult: SentimentResult,
        config: AppConfig
    ) -> SessionActivityState {
        let transcript = buildTranscript(from: observations)
        let positiveTriggerSet = Set(sentimentResult.positiveTriggers)
        let negativeTriggerCount = Set(sentimentResult.negativeTriggers + sentimentResult.frustrationTriggers).count
        let hasRepeatedNegativeLines = !sentimentResult.repeatedNegativeLines.isEmpty

        if !positiveTriggerSet.isDisjoint(with: celebratingTokens),
           sentimentResult.finalAngerScore < config.calmUpperBound,
           !hasRepeatedNegativeLines {
            return .celebrating
        }

        if sentimentResult.finalAngerScore >= config.curiousUpperBound ||
            hasRepeatedNegativeLines ||
            negativeTriggerCount >= 2 {
            return .blocked
        }

        if sentimentResult.finalAngerScore < config.calmUpperBound,
           transcript.count >= 120,
           sentimentResult.negativeTriggers.isEmpty,
           sentimentResult.frustrationTriggers.isEmpty,
           proseLikeScore(in: transcript) > codeLikeScore(in: transcript) {
            return .reading
        }

        if sentimentResult.finalAngerScore < config.curiousUpperBound,
           hasLowTranscriptNovelty(in: observations) {
            return .thinking
        }

        return .default
    }

    private func buildTranscript(from observations: [TextObservation]) -> String {
        var seen = Set<String>()
        var lines: [String] = []

        for observation in observations.sorted(by: { $0.timestamp < $1.timestamp }) {
            for line in TextNormalizer.splitLines(in: observation.rawText) {
                let normalized = TextNormalizer.normalizeLine(line)
                guard !normalized.isEmpty else { continue }
                guard seen.insert(normalized).inserted else { continue }
                lines.append(line)
            }
        }

        return lines.joined(separator: "\n")
    }

    private func proseLikeScore(in transcript: String) -> Int {
        let tokens = TextNormalizer.tokens(in: transcript)
        let proseTokenScore = tokens.filter { proseStopWords.contains($0) }.count
        let proseLineScore = transcript
            .components(separatedBy: .newlines)
            .filter { TextNormalizer.tokens(in: $0).count >= 8 }
            .count * 2

        return proseTokenScore + proseLineScore
    }

    private func codeLikeScore(in transcript: String) -> Int {
        let lines = transcript.components(separatedBy: .newlines)
        let symbolHeavyLineScore = lines.filter {
            $0.range(
                of: #"[{}\[\]();=<>#:/._-]"#,
                options: .regularExpression
            ) != nil
        }.count * 2

        let tokens = TextNormalizer.tokens(in: transcript)
        let codeKeywordScore = tokens.filter { codeKeywords.contains($0) }.count

        return symbolHeavyLineScore + codeKeywordScore
    }

    private func hasLowTranscriptNovelty(in observations: [TextObservation]) -> Bool {
        let recentObservations = Array(observations.sorted(by: { $0.timestamp < $1.timestamp }).suffix(3))
        guard recentObservations.count >= 2 else {
            return false
        }

        var seen = Set<String>()
        var trailingNovelty = 0

        for (index, observation) in recentObservations.enumerated() {
            let lines = TextNormalizer.splitLines(in: observation.normalizedText)
            let freshLines = lines.filter { seen.insert($0).inserted }.count

            if index >= recentObservations.count - 2 {
                trailingNovelty += freshLines
            }
        }

        if trailingNovelty == 0 {
            return true
        }

        let lastObservationLength = recentObservations.last?.normalizedText.count ?? 0
        return trailingNovelty == 1 && lastObservationLength < 80
    }
}

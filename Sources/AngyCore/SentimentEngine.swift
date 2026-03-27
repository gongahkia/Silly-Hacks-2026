import Foundation
import NaturalLanguage

public struct SentimentEngine: Sendable {
    private let config: AppConfig

    private let negativeTokenWeights: [String: Double] = [
        "error": 8,
        "failed": 8,
        "exception": 9,
        "timeout": 8,
        "undefined": 7,
        "cannot": 6,
        "invalid": 6,
        "retry": 4,
        "refused": 6,
        "broken": 5,
        "panic": 9
    ]

    private let frustrationTokenWeights: [String: Double] = [
        "why": 4,
        "still": 4,
        "again": 5,
        "wtf": 9,
        "ugh": 5,
        "seriously": 4
    ]

    private let positiveTokenWeights: [String: Double] = [
        "fixed": -9,
        "passed": -8,
        "success": -8,
        "done": -6,
        "working": -7,
        "solved": -8,
        "resolved": -8
    ]

    public init(config: AppConfig = .live) {
        self.config = config
    }

    public func analyze(
        observations: [TextObservation],
        previousAngerScore: Double,
        previousState: CompanionState
    ) -> SentimentResult {
        let transcript = buildTranscript(from: observations)
        guard !transcript.isEmpty else {
            let decayedScore = clamp(previousAngerScore * config.decayFactor)
            return SentimentResult(
                baseSentimentScore: 0,
                heuristicAdjustment: 0,
                finalAngerScore: decayedScore,
                matchedTriggers: [],
                currentState: mapState(for: decayedScore, previousState: previousState)
            )
        }

        let baseSentiment = sentimentScore(for: transcript)
        let negativeSentimentComponent = max(0, -baseSentiment) * 40
        let heuristic = heuristicAdjustment(from: transcript, observations: observations)
        let rawAngerScore = clamp(negativeSentimentComponent + heuristic.adjustment)
        let preservedWeight = rawAngerScore > previousAngerScore ? 0.4 : config.smoothingFactor
        let smoothedScore = clamp(
            (previousAngerScore * preservedWeight) +
            (rawAngerScore * (1 - preservedWeight))
        )

        return SentimentResult(
            baseSentimentScore: baseSentiment,
            heuristicAdjustment: heuristic.adjustment,
            finalAngerScore: smoothedScore,
            matchedTriggers: heuristic.matches,
            currentState: mapState(for: smoothedScore, previousState: previousState)
        )
    }

    private func buildTranscript(from observations: [TextObservation]) -> String {
        var seen = Set<String>()
        var dedupedLines: [String] = []

        for observation in observations.sorted(by: { $0.timestamp < $1.timestamp }) {
            for line in TextNormalizer.splitLines(in: observation.rawText) {
                let normalized = TextNormalizer.normalizeLine(line)
                guard !normalized.isEmpty else { continue }
                guard seen.insert(normalized).inserted else { continue }
                dedupedLines.append(line)
            }
        }

        return dedupedLines.joined(separator: "\n")
    }

    private func sentimentScore(for text: String) -> Double {
        guard #available(macOS 10.15, *) else {
            return lexicalSentimentFallback(for: text)
        }

        let tagger = NLTagger(tagSchemes: [.sentimentScore])
        tagger.string = text

        var scores: [Double] = []
        let range = text.startIndex..<text.endIndex
        tagger.enumerateTags(
            in: range,
            unit: .paragraph,
            scheme: .sentimentScore,
            options: [.omitWhitespace, .omitPunctuation]
        ) { tag, _ in
            if let rawValue = tag?.rawValue, let score = Double(rawValue) {
                scores.append(score)
            }
            return true
        }

        let (fallbackTag, _) = tagger.tag(
            at: text.startIndex,
            unit: .paragraph,
            scheme: .sentimentScore
        )

        if scores.isEmpty,
           let fallbackTag,
           let score = Double(fallbackTag.rawValue) {
            scores.append(score)
        }

        guard !scores.isEmpty else {
            return lexicalSentimentFallback(for: text)
        }
        return scores.reduce(0, +) / Double(scores.count)
    }

    private func lexicalSentimentFallback(for text: String) -> Double {
        let tokens = TextNormalizer.tokens(in: text)
        guard !tokens.isEmpty else { return 0 }

        var score = 0.0

        for token in tokens {
            if let weight = positiveTokenWeights[token] {
                score += abs(weight)
            }

            if let weight = negativeTokenWeights[token] {
                score -= weight
            }

            if let weight = frustrationTokenWeights[token] {
                score -= weight * 0.75
            }
        }

        let normalizedScore = score / Double(max(tokens.count, 1))
        return max(-1, min(1, normalizedScore / 6))
    }

    private func heuristicAdjustment(
        from text: String,
        observations: [TextObservation]
    ) -> (adjustment: Double, matches: [String]) {
        let normalized = TextNormalizer.normalize(text)
        let tokens = TextNormalizer.tokens(in: normalized)
        var adjustment = 0.0
        var matches: [String] = []

        for token in tokens {
            if let weight = negativeTokenWeights[token] {
                adjustment += weight
                matches.append(token)
            }

            if let weight = frustrationTokenWeights[token] {
                adjustment += weight
                matches.append(token)
            }

            if let weight = positiveTokenWeights[token] {
                adjustment += weight
                matches.append(token)
            }
        }

        let questionBurstCount = normalized.components(separatedBy: "???").count - 1
        if questionBurstCount > 0 {
            adjustment += Double(questionBurstCount) * 8
            matches.append("???")
        }

        let repeatedLineCounts = repeatedNegativeLineCounts(in: observations)
        if !repeatedLineCounts.isEmpty {
            let repeatPenalty = min(18.0, Double(repeatedLineCounts.values.reduce(0, +) - repeatedLineCounts.count) * 4)
            adjustment += repeatPenalty
            matches.append(contentsOf: repeatedLineCounts.keys.map { "repeat:\($0)" })
        }

        return (adjustment, matches.sorted())
    }

    private func repeatedNegativeLineCounts(in observations: [TextObservation]) -> [String: Int] {
        var counts: [String: Int] = [:]

        for observation in observations {
            for line in TextNormalizer.splitLines(in: observation.normalizedText) {
                let tokenSet = Set(TextNormalizer.tokens(in: line))
                guard tokenSet.contains(where: isNegativeToken) else { continue }
                counts[line, default: 0] += 1
            }
        }

        return counts.filter { $0.value > 1 }
    }

    private func isNegativeToken(_ token: String) -> Bool {
        negativeTokenWeights[token] != nil || frustrationTokenWeights[token] != nil
    }

    private func mapState(for angerScore: Double, previousState: CompanionState) -> CompanionState {
        switch previousState {
        case .calm:
            if angerScore > config.calmUpperBound + config.hysteresis {
                return angerScore > config.curiousUpperBound + config.hysteresis ? .annoyed : .curious
            }
            return .calm
        case .curious:
            if angerScore < config.calmUpperBound - config.hysteresis {
                return .calm
            }
            if angerScore > config.curiousUpperBound + config.hysteresis {
                return angerScore > config.annoyedUpperBound + config.hysteresis ? .furious : .annoyed
            }
            return .curious
        case .annoyed:
            if angerScore < config.curiousUpperBound - config.hysteresis {
                return angerScore < config.calmUpperBound - config.hysteresis ? .calm : .curious
            }
            if angerScore > config.annoyedUpperBound + config.hysteresis {
                return .furious
            }
            return .annoyed
        case .furious:
            if angerScore < config.annoyedUpperBound - config.hysteresis {
                return angerScore < config.curiousUpperBound - config.hysteresis ? .curious : .annoyed
            }
            return .furious
        }
    }

    private func clamp(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}

import AngyCore
import Foundation
import XCTest

final class SessionActivityClassifierTests: XCTestCase {
    private let classifier = SessionActivityClassifier()

    func testDefaultClassificationFallsBackWhenSignalsAreNeutral() {
        let observations = [
            makeObservation(
                offset: 0,
                rawText: "running the same command again"
            )
        ]

        let result = classifier.classify(
            observations: observations,
            sentimentResult: makeSentimentResult(anger: 10, state: .calm),
            config: .live
        )

        XCTAssertEqual(result, .default)
    }

    func testReadingClassificationPrefersLongProseTranscript() {
        let rawText = """
        The onboarding notes explain how the window tracker behaves when Accessibility is missing, \
        why the OCR fallback exists, and what the companion should show while the user is reading docs.
        """
        let observations = [
            makeObservation(offset: 0, rawText: rawText)
        ]

        let result = classifier.classify(
            observations: observations,
            sentimentResult: makeSentimentResult(anger: 8, state: .calm),
            config: .live
        )

        XCTAssertEqual(result, .reading)
    }

    func testThinkingClassificationDetectsLowTranscriptNovelty() {
        let observations = [
            makeObservation(offset: 0, rawText: "thinking through the next refactor"),
            makeObservation(offset: 1, rawText: "thinking through the next refactor"),
            makeObservation(offset: 2, rawText: "thinking through the next refactor")
        ]

        let result = classifier.classify(
            observations: observations,
            sentimentResult: makeSentimentResult(anger: 18, state: .curious),
            config: .live
        )

        XCTAssertEqual(result, .thinking)
    }

    func testBlockedClassificationTriggersFromNegativeSignals() {
        let observations = [
            makeObservation(offset: 0, rawText: "error timeout while retrying")
        ]

        let result = classifier.classify(
            observations: observations,
            sentimentResult: makeSentimentResult(
                anger: 52,
                state: .annoyed,
                negative: ["error", "timeout"],
                frustration: ["again"]
            ),
            config: .live
        )

        XCTAssertEqual(result, .blocked)
    }

    func testCelebratingClassificationWinsWhenPositiveSignalsAreClean() {
        let observations = [
            makeObservation(offset: 0, rawText: "fixed the flaky tests and the build passed cleanly")
        ]

        let result = classifier.classify(
            observations: observations,
            sentimentResult: makeSentimentResult(
                anger: 6,
                state: .calm,
                positive: ["fixed", "passed"]
            ),
            config: .live
        )

        XCTAssertEqual(result, .celebrating)
    }

    func testCelebratingPrecedenceBeatsReadingAndThinking() {
        let rawText = """
        The migration notes explain the release steps in detail, but the last line says the issue is fixed \
        and the deployment passed without further errors.
        """
        let observations = [
            makeObservation(offset: 0, rawText: rawText),
            makeObservation(offset: 1, rawText: rawText)
        ]

        let result = classifier.classify(
            observations: observations,
            sentimentResult: makeSentimentResult(
                anger: 10,
                state: .calm,
                positive: ["fixed", "passed"]
            ),
            config: .live
        )

        XCTAssertEqual(result, .celebrating)
    }

    func testBlockedPrecedenceBeatsReadingAndThinking() {
        let rawText = """
        The long design note keeps talking about release plans and implementation details, \
        but timeout error again is still showing up in every pass.
        """
        let observations = [
            makeObservation(offset: 0, rawText: rawText),
            makeObservation(offset: 1, rawText: rawText)
        ]

        let result = classifier.classify(
            observations: observations,
            sentimentResult: makeSentimentResult(
                anger: 48,
                state: .annoyed,
                negative: ["timeout", "error"],
                frustration: ["again"]
            ),
            config: .live
        )

        XCTAssertEqual(result, .blocked)
    }

    private func makeObservation(offset: TimeInterval, rawText: String) -> TextObservation {
        let timestamp = Date(timeIntervalSinceReferenceDate: 100 + offset)
        return TextObservation(
            timestamp: timestamp,
            source: .accessibility,
            rawText: rawText,
            normalizedText: TextNormalizer.normalize(rawText),
            confidence: 1
        )
    }

    private func makeSentimentResult(
        anger: Double,
        state: CompanionState,
        positive: [String] = [],
        negative: [String] = [],
        frustration: [String] = [],
        repeatedNegativeLines: [String: Int] = [:]
    ) -> SentimentResult {
        let repeatTriggers = repeatedNegativeLines.keys.map { "repeat:\($0)" }
        return SentimentResult(
            baseSentimentScore: 0,
            heuristicAdjustment: 0,
            finalAngerScore: anger,
            matchedTriggers: (positive + negative + frustration + repeatTriggers).sorted(),
            positiveTriggers: positive.sorted(),
            negativeTriggers: negative.sorted(),
            frustrationTriggers: frustration.sorted(),
            repeatedNegativeLines: repeatedNegativeLines,
            currentState: state
        )
    }
}

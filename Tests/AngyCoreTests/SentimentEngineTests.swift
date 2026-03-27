import AngyCore
import Foundation
import XCTest

final class SentimentEngineTests: XCTestCase {
    func testPositiveTranscriptStaysCalm() {
        let engine = SentimentEngine(config: .live)
        let now = Date()
        let observations = [
            TextObservation(
                timestamp: now,
                source: .accessibility,
                rawText: "fixed the flaky test\nbuild passed\nworking now",
                normalizedText: TextNormalizer.normalize("fixed the flaky test\nbuild passed\nworking now"),
                confidence: 1
            )
        ]

        let result = engine.analyze(observations: observations, previousAngerScore: 0, previousState: .calm)

        XCTAssertLessThan(result.finalAngerScore, 12)
        XCTAssertEqual(result.currentState, .calm)
    }

    func testRepeatedErrorsEscalateIntoHighAnger() {
        let engine = SentimentEngine(config: .live)
        let now = Date()
        let rawText = "error: request failed again\nwhy is this still broken???\ntimeout while retrying"
        let normalized = TextNormalizer.normalize(rawText)
        let observations = [
            TextObservation(timestamp: now, source: .accessibility, rawText: rawText, normalizedText: normalized, confidence: 1),
            TextObservation(timestamp: now.addingTimeInterval(1), source: .ocr, rawText: rawText, normalizedText: normalized, confidence: 0.82),
            TextObservation(timestamp: now.addingTimeInterval(2), source: .ocr, rawText: rawText, normalizedText: normalized, confidence: 0.78)
        ]

        let result = engine.analyze(observations: observations, previousAngerScore: 46, previousState: .annoyed)

        XCTAssertGreaterThanOrEqual(result.finalAngerScore, 70)
        XCTAssertEqual(result.currentState, .furious)
        XCTAssertTrue(result.matchedTriggers.contains("error"))
        XCTAssertTrue(result.matchedTriggers.contains("timeout"))
    }

    func testHysteresisPreventsImmediateStateDrop() {
        let engine = SentimentEngine(config: .live)
        let now = Date()
        let observations = [
            TextObservation(
                timestamp: now,
                source: .accessibility,
                rawText: "still weird but getting closer",
                normalizedText: TextNormalizer.normalize("still weird but getting closer"),
                confidence: 1
            )
        ]

        let result = engine.analyze(observations: observations, previousAngerScore: 48, previousState: .annoyed)

        XCTAssertLessThan(result.finalAngerScore, 48)
        XCTAssertEqual(result.currentState, .annoyed)
    }
}

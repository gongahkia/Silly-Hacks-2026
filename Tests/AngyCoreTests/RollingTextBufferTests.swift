import AngyCore
import Foundation
import XCTest

final class RollingTextBufferTests: XCTestCase {
    func testRollingBufferDedupesTranscriptLines() {
        let buffer = RollingTextBuffer(windowDuration: 20)
        let now = Date()

        buffer.append(
            TextObservation(
                timestamp: now,
                source: .accessibility,
                rawText: "error: build failed\nstill broken",
                normalizedText: TextNormalizer.normalize("error: build failed\nstill broken"),
                confidence: 1
            ),
            now: now
        )

        buffer.append(
            TextObservation(
                timestamp: now.addingTimeInterval(1),
                source: .ocr,
                rawText: "error: build failed\nfixed now",
                normalizedText: TextNormalizer.normalize("error: build failed\nfixed now"),
                confidence: 0.82
            ),
            now: now.addingTimeInterval(1)
        )

        XCTAssertEqual(
            buffer.recentTranscript(now: now.addingTimeInterval(1)),
            "error: build failed\nstill broken\nfixed now"
        )
    }

    func testRollingBufferCountsRepeatedLines() {
        let buffer = RollingTextBuffer(windowDuration: 20)
        let now = Date()
        let line = "timeout while connecting"

        for offset in 0..<3 {
            buffer.append(
                TextObservation(
                    timestamp: now.addingTimeInterval(Double(offset)),
                    source: .ocr,
                    rawText: line,
                    normalizedText: TextNormalizer.normalize(line),
                    confidence: 0.8
                ),
                now: now.addingTimeInterval(Double(offset))
            )
        }

        XCTAssertEqual(
            buffer.repeatedLineCounts(now: now.addingTimeInterval(2))[TextNormalizer.normalize(line)],
            3
        )
    }
}

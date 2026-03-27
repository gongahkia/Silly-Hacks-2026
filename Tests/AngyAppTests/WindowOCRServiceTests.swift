import XCTest
@testable import Angy

final class WindowOCRServiceTests: XCTestCase {
    func testSanitizedRecognizedTextDropsAngyLauncherAndDebugNoise() {
        let sanitized = WindowOCRService.sanitizedRecognizedText(from: [
            "❯ ANGY_DEBUG=1 swift run Angy",
            "Building for debugging...",
            "[AngyDebug] debug logging enabled",
            "[AngyDebug] ascii panda + hamster sidecar mode active",
            "error: request failed again",
            "why is this still broken???",
            "timeout while retrying"
        ])

        XCTAssertEqual(
            sanitized,
            """
            error: request failed again
            why is this still broken???
            timeout while retrying
            """
        )
    }
}

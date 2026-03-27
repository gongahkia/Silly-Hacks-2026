import XCTest
@testable import Angy

final class AccessibilityTextExtractorTests: XCTestCase {
    func testSanitizedExtractedTextStripsRepeatedWindowChrome() {
        let rawText = """
        swift run Angy
        swift run Angy
        swift run Angy, workspace 1 of 6
        error: request failed again
        why is this still broken???
        timeout while retrying
        """

        let sanitized = AccessibilityTextExtractor.sanitizedExtractedText(
            from: rawText,
            windowTitle: "swift run Angy, workspace 1 of 6"
        )

        XCTAssertEqual(
            sanitized,
            """
            error: request failed again
            why is this still broken???
            timeout while retrying
            """
        )
    }

    func testSanitizedExtractedTextRejectsChromeOnlyAccessibilityDump() {
        let rawText = """
        swift run Angy
        swift run Angy
        swift run Angy, workspace 1 of 6
        swift run Angy
        """

        XCTAssertNil(
            AccessibilityTextExtractor.sanitizedExtractedText(
                from: rawText,
                windowTitle: "swift run Angy, workspace 1 of 6"
            )
        )
    }

    func testSanitizedExtractedTextRejectsWorkspaceBoilerplate() {
        let rawText = """
        Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions.
        Project notes, workspace 2 of 6
        Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions.
        """

        XCTAssertNil(
            AccessibilityTextExtractor.sanitizedExtractedText(
                from: rawText,
                windowTitle: "Project notes, workspace 2 of 6"
            )
        )
    }
}

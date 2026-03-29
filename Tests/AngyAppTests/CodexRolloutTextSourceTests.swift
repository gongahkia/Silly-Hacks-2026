import XCTest
@testable import Angy

final class CodexRolloutTextSourceTests: XCTestCase {
    func testParsesAgentMessageEventLine() {
        let line = """
        {"timestamp":"2026-03-29T11:36:37.404Z","type":"event_msg","payload":{"type":"agent_message","message":"it blew up","phase":"final_answer"}}
        """

        let parsed = CodexRolloutTextSource.parseMessage(fromJSONLine: line)

        XCTAssertEqual(parsed?.message, "it blew up")
        XCTAssertNotNil(parsed?.timestamp)
    }

    func testParsesTaskCompleteEventLine() {
        let line = """
        {"timestamp":"2026-03-29T11:36:37.404Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"all fixed"}}
        """

        let parsed = CodexRolloutTextSource.parseMessage(fromJSONLine: line)

        XCTAssertEqual(parsed?.message, "all fixed")
        XCTAssertNotNil(parsed?.timestamp)
    }

    func testParsesAssistantResponseItemLine() {
        let line = """
        {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"line one"},{"type":"output_text","text":"line two"}]}}
        """

        let parsed = CodexRolloutTextSource.parseMessage(fromJSONLine: line)

        XCTAssertEqual(parsed?.message, "line one\nline two")
    }

    func testIgnoresNonAssistantResponseItemLine() {
        let line = """
        {"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"output_text","text":"hello"}]}}
        """

        XCTAssertNil(CodexRolloutTextSource.parseMessage(fromJSONLine: line))
    }
}

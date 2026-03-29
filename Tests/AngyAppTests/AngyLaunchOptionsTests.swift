import XCTest
@testable import Angy

final class AngyLaunchOptionsTests: XCTestCase {
    func testDefaultsToCodexSessionMode() {
        let options = AngyLaunchOptions.parse(
            arguments: [],
            environment: [:],
            homeDirectoryURL: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )

        XCTAssertEqual(options.textIngestionMode, .codexSessions)
        XCTAssertEqual(
            options.codexHomeDirectory,
            URL(fileURLWithPath: "/Users/test/.codex", isDirectory: true).standardizedFileURL
        )
    }

    func testLegacyFlagForcesLegacyScreenCaptureMode() {
        let options = AngyLaunchOptions.parse(
            arguments: ["--legacy"],
            environment: [:],
            homeDirectoryURL: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )

        XCTAssertEqual(options.textIngestionMode, .legacyScreenCapture)
    }

    func testLegacyEnvironmentForcesLegacyScreenCaptureMode() {
        let options = AngyLaunchOptions.parse(
            arguments: [],
            environment: ["ANGY_LEGACY": "true"],
            homeDirectoryURL: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )

        XCTAssertEqual(options.textIngestionMode, .legacyScreenCapture)
    }

    func testCodexHomeEnvironmentOverride() {
        let options = AngyLaunchOptions.parse(
            arguments: [],
            environment: ["ANGY_CODEX_HOME": "~/custom-codex-home"],
            homeDirectoryURL: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )

        XCTAssertEqual(
            options.codexHomeDirectory,
            URL(fileURLWithPath: "/Users/test/custom-codex-home", isDirectory: true).standardizedFileURL
        )
    }
}

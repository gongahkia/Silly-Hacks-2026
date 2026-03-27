import AngyCore
import XCTest

final class AppConfigTests: XCTestCase {
    func testLiveConfigTargetsSupportedApps() {
        XCTAssertTrue(AppConfig.live.targetBundleIDs.contains("com.openai.codex"))
        XCTAssertTrue(AppConfig.live.targetBundleIDs.contains("com.mitchellh.ghostty"))
        XCTAssertTrue(AppConfig.live.targetBundleIDs.contains("com.cmuxterm.app"))

        XCTAssertTrue(AppConfig.live.targetOwnerNames.contains("Codex"))
        XCTAssertTrue(AppConfig.live.targetOwnerNames.contains("Ghostty"))
        XCTAssertTrue(AppConfig.live.targetOwnerNames.contains("cmux"))
    }
}

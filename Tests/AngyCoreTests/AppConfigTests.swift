import AngyCore
import XCTest

final class AppConfigTests: XCTestCase {
    func testLiveConfigTargetsSupportedApps() {
        XCTAssertTrue(AppConfig.live.targetBundleIDs.contains("com.openai.codex"))
        XCTAssertTrue(AppConfig.live.targetBundleIDs.contains("com.mitchellh.ghostty"))
        XCTAssertFalse(AppConfig.live.targetBundleIDs.contains("com.cmuxterm.app"))

        XCTAssertTrue(AppConfig.live.targetOwnerNames.contains("Codex"))
        XCTAssertTrue(AppConfig.live.targetOwnerNames.contains("Ghostty"))
        XCTAssertFalse(AppConfig.live.targetOwnerNames.contains("cmux"))
    }

    func testLiveConfigIncludesSpawnedWindowAndHateMailDefaults() {
        XCTAssertEqual(AppConfig.live.spawnedWindowRefreshInterval, 0.25, accuracy: 0.001)
        XCTAssertEqual(AppConfig.live.hateMailCooldown, 600, accuracy: 0.001)
        XCTAssertEqual(AppConfig.live.hateMailOutputFolderName, "Angy Hate Mail")
    }
}

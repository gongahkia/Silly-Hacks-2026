import XCTest
@testable import Angy

final class WindowTrackerAppSelectorTests: XCTestCase {
    func testPrefersCodexWhenFrontmostTerminalLooksLikeAngyLauncher() {
        let frontmost = RunningAppSnapshot(
            bundleID: "com.mitchellh.ghostty",
            appName: "Ghostty",
            pid: 10,
            isHidden: false
        )
        let codex = RunningAppSnapshot(
            bundleID: "com.openai.codex",
            appName: "Codex",
            pid: 20,
            isHidden: false
        )

        let selected = WindowTrackerAppSelector.selectObservedAppContext(
            frontmostApp: frontmost,
            focusedWindowTitle: "swift run Angy, workspace 1 of 6",
            runningApps: [frontmost, codex],
            targetBundleIDs: ["com.openai.codex", "com.mitchellh.ghostty"]
        )

        XCTAssertEqual(selected?.bundleID, "com.openai.codex")
        XCTAssertEqual(selected?.pid, 20)
    }

    func testKeepsFrontmostTerminalWhenItIsNotTheAngyLauncher() {
        let frontmost = RunningAppSnapshot(
            bundleID: "com.mitchellh.ghostty",
            appName: "Ghostty",
            pid: 10,
            isHidden: false
        )
        let codex = RunningAppSnapshot(
            bundleID: "com.openai.codex",
            appName: "Codex",
            pid: 20,
            isHidden: false
        )

        let selected = WindowTrackerAppSelector.selectObservedAppContext(
            frontmostApp: frontmost,
            focusedWindowTitle: "bug bash tmux session",
            runningApps: [frontmost, codex],
            targetBundleIDs: ["com.openai.codex", "com.mitchellh.ghostty"]
        )

        XCTAssertEqual(selected?.bundleID, "com.mitchellh.ghostty")
        XCTAssertEqual(selected?.pid, 10)
    }

    func testIgnoresAngyLauncherTerminalWhenCodexIsNotRunning() {
        let frontmost = RunningAppSnapshot(
            bundleID: "com.mitchellh.ghostty",
            appName: "Ghostty",
            pid: 10,
            isHidden: false
        )

        let selected = WindowTrackerAppSelector.selectObservedAppContext(
            frontmostApp: frontmost,
            focusedWindowTitle: "swift run Angy, workspace 1 of 6",
            runningApps: [frontmost],
            targetBundleIDs: ["com.openai.codex", "com.mitchellh.ghostty"]
        )

        XCTAssertNil(selected)
    }
}

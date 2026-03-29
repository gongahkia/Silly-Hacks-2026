import Foundation

enum TextIngestionMode: String, Sendable {
    case codexSessions
    case legacyScreenCapture
}

struct AngyLaunchOptions: Equatable, Sendable {
    let textIngestionMode: TextIngestionMode
    let codexHomeDirectory: URL

    static func current(processInfo: ProcessInfo = .processInfo) -> AngyLaunchOptions {
        parse(
            arguments: Array(processInfo.arguments.dropFirst()),
            environment: processInfo.environment,
            homeDirectoryURL: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    static func parse(
        arguments: [String],
        environment: [String: String],
        homeDirectoryURL: URL
    ) -> AngyLaunchOptions {
        let legacyFlag = arguments.contains("--legacy")
        let legacyEnvironment = isTruthy(environment["ANGY_LEGACY"])
        let textIngestionMode: TextIngestionMode = (legacyFlag || legacyEnvironment)
            ? .legacyScreenCapture
            : .codexSessions

        let codexHomePath = environment["ANGY_CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let codexHomeDirectory: URL
        if let codexHomePath, !codexHomePath.isEmpty {
            codexHomeDirectory = expandedFileURL(from: codexHomePath, homeDirectoryURL: homeDirectoryURL)
        } else {
            codexHomeDirectory = homeDirectoryURL.appendingPathComponent(".codex", isDirectory: true)
        }

        return AngyLaunchOptions(
            textIngestionMode: textIngestionMode,
            codexHomeDirectory: codexHomeDirectory.standardizedFileURL
        )
    }

    private static func expandedFileURL(from rawPath: String, homeDirectoryURL: URL) -> URL {
        if rawPath == "~" {
            return homeDirectoryURL
        }

        if rawPath.hasPrefix("~/") {
            let suffix = String(rawPath.dropFirst(2))
            return homeDirectoryURL.appendingPathComponent(suffix, isDirectory: true)
        }

        return URL(fileURLWithPath: rawPath, isDirectory: true)
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let value else {
            return false
        }

        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }
}

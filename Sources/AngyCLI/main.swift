import AngyCore
import Foundation

private struct ControlPlaneDiscovery: Codable {
    let port: UInt16
    let token: String
}

private struct SpawnRequestBody: Codable {
    let frontmost: Bool?
    let windowID: UInt32?
}

private struct RetargetRequestBody: Codable {
    let windowID: UInt32
}

private struct OverrideStateBody: Codable {
    let state: CompanionState
}

private struct SettingBody: Codable {
    let key: String
    let value: String
}

@main
struct AngyCLIMain {
    static func main() async {
        do {
            let cli = try AngyCLI()
            try await cli.run()
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

private struct AngyCLI {
    private let discovery: ControlPlaneDiscovery
    private let arguments: [String]

    init() throws {
        let arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
        self.arguments = arguments

        let discoveryURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Angy", isDirectory: true)
            .appendingPathComponent("control-plane.json", isDirectory: false)
        guard let discoveryURL,
              let data = try? Data(contentsOf: discoveryURL) else {
            throw CLIError.controlPlaneUnavailable
        }

        self.discovery = try JSONDecoder().decode(ControlPlaneDiscovery.self, from: data)
    }

    func run() async throws {
        guard let first = arguments.first else {
            throw CLIError.usage
        }

        switch first {
        case "windows":
            try await runWindows(arguments: Array(arguments.dropFirst()))
        case "instances":
            try await runInstances(arguments: Array(arguments.dropFirst()))
        case "settings":
            try await runSettings(arguments: Array(arguments.dropFirst()))
        default:
            throw CLIError.usage
        }
    }

    private func runWindows(arguments: [String]) async throws {
        guard arguments.first == "list" else {
            throw CLIError.usage
        }

        let jsonOutput = arguments.contains("--json")
        let response = try await send(method: "GET", path: "/v1/windows")
        try printResponse(response, jsonOutput: jsonOutput)
    }

    private func runInstances(arguments: [String]) async throws {
        guard let subcommand = arguments.first else {
            throw CLIError.usage
        }

        let remaining = Array(arguments.dropFirst())

        switch subcommand {
        case "list":
            let response = try await send(method: "GET", path: "/v1/instances")
            try printResponse(response, jsonOutput: remaining.contains("--json"))
        case "spawn":
            if remaining.first == "--frontmost" {
                let body = try JSONEncoder().encode(SpawnRequestBody(frontmost: true, windowID: nil))
                let response = try await send(method: "POST", path: "/v1/instances", body: body)
                try printResponse(response, jsonOutput: false)
            } else if remaining.first == "--window-id", remaining.count >= 2, let windowID = UInt32(remaining[1]) {
                let body = try JSONEncoder().encode(SpawnRequestBody(frontmost: false, windowID: windowID))
                let response = try await send(method: "POST", path: "/v1/instances", body: body)
                try printResponse(response, jsonOutput: false)
            } else {
                throw CLIError.usage
            }
        case "remove":
            guard let id = remaining.first else {
                throw CLIError.usage
            }
            let response = try await send(method: "DELETE", path: "/v1/instances/\(encode(id))")
            try printResponse(response, jsonOutput: false)
        case "pause":
            guard let id = remaining.first else {
                throw CLIError.usage
            }
            let response = try await send(method: "POST", path: "/v1/instances/\(encode(id))/pause", body: Data())
            try printResponse(response, jsonOutput: false)
        case "resume":
            guard let id = remaining.first else {
                throw CLIError.usage
            }
            let response = try await send(method: "POST", path: "/v1/instances/\(encode(id))/resume", body: Data())
            try printResponse(response, jsonOutput: false)
        case "target":
            guard remaining.count >= 3, remaining[1] == "--window-id", let windowID = UInt32(remaining[2]) else {
                throw CLIError.usage
            }
            let body = try JSONEncoder().encode(RetargetRequestBody(windowID: windowID))
            let response = try await send(method: "POST", path: "/v1/instances/\(encode(remaining[0]))/target", body: body)
            try printResponse(response, jsonOutput: false)
        case "set-state":
            guard remaining.count >= 2,
                  let state = CompanionState(rawValue: remaining[1].lowercased()) else {
                throw CLIError.usage
            }
            let body = try JSONEncoder().encode(OverrideStateBody(state: state))
            let response = try await send(method: "POST", path: "/v1/instances/\(encode(remaining[0]))/override-state", body: body)
            try printResponse(response, jsonOutput: false)
        case "clear-state":
            guard let id = remaining.first else {
                throw CLIError.usage
            }
            let response = try await send(method: "DELETE", path: "/v1/instances/\(encode(id))/override-state")
            try printResponse(response, jsonOutput: false)
        case "explode":
            guard let id = remaining.first else {
                throw CLIError.usage
            }
            let response = try await send(method: "POST", path: "/v1/instances/\(encode(id))/explode", body: Data())
            try printResponse(response, jsonOutput: false)
        case "hate-mail":
            guard let id = remaining.first else {
                throw CLIError.usage
            }
            let response = try await send(method: "POST", path: "/v1/instances/\(encode(id))/hate-mail", body: Data())
            try printResponse(response, jsonOutput: false)
        default:
            throw CLIError.usage
        }
    }

    private func runSettings(arguments: [String]) async throws {
        guard let subcommand = arguments.first else {
            throw CLIError.usage
        }

        switch subcommand {
        case "get":
            let response = try await send(method: "GET", path: "/v1/settings")
            try printResponse(response, jsonOutput: arguments.contains("--json"))
        case "set":
            guard arguments.count >= 3 else {
                throw CLIError.usage
            }
            let body = try JSONEncoder().encode(SettingBody(key: arguments[1], value: arguments[2]))
            let response = try await send(method: "POST", path: "/v1/settings", body: body)
            try printResponse(response, jsonOutput: false)
        default:
            throw CLIError.usage
        }
    }

    private func send(method: String, path: String, body: Data? = nil) async throws -> (Data, AngyControlResponse) {
        guard let url = URL(string: "http://127.0.0.1:\(discovery.port)\(path)") else {
            throw CLIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(discovery.token, forHTTPHeaderField: "X-Angy-Token")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw CLIError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(AngyControlResponse.self, from: data)
        guard (200..<300).contains(httpResponse.statusCode), decoded.ok else {
            throw CLIError.server(decoded.message ?? "The Angy control plane rejected the request.")
        }

        return (data, decoded)
    }

    private func printResponse(_ response: (Data, AngyControlResponse), jsonOutput: Bool) throws {
        if jsonOutput {
            if let json = String(data: response.0, encoding: .utf8) {
                print(json)
            }
            return
        }

        if let message = response.1.message, !message.isEmpty {
            print(message)
            return
        }

        if let windows = response.1.windows {
            for window in windows {
                let title = window.title?.isEmpty == false ? window.title! : "Untitled Window"
                print("\(window.windowID)\t\(window.appName)\t\(title)")
            }
            return
        }

        if let instances = response.1.instances {
            for instance in instances {
                let label = instance.tag ?? instance.role.rawValue.capitalized
                let title = instance.target?.title?.isEmpty == false ? instance.target!.title! : "Detached"
                print("\(label)\t\(instance.emotion.rawValue)\t\(title)")
            }
            return
        }

        if let settings = response.1.settings {
            print("pauseAll=\(settings.pauseAll)")
            print("hateMailEnabled=\(settings.hateMailEnabled)")
            print("soundEnabled=\(settings.soundEnabled)")
        }
    }

    private func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}

private enum CLIError: LocalizedError {
    case usage
    case controlPlaneUnavailable
    case invalidURL
    case invalidResponse
    case server(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            return """
            Usage:
              AngyCLI windows list [--json]
              AngyCLI instances list [--json]
              AngyCLI instances spawn --frontmost
              AngyCLI instances spawn --window-id <id>
              AngyCLI instances remove <id|#tag>
              AngyCLI instances pause <id|#tag>
              AngyCLI instances resume <id|#tag>
              AngyCLI instances target <id|#tag> --window-id <id>
              AngyCLI instances set-state <id|#tag> <calm|curious|annoyed|furious>
              AngyCLI instances clear-state <id|#tag>
              AngyCLI instances explode <id|#tag>
              AngyCLI instances hate-mail <id|#tag>
              AngyCLI settings get [--json]
              AngyCLI settings set <key> <value>
            """
        case .controlPlaneUnavailable:
            return "Angy is not running or has not published its control-plane discovery file."
        case .invalidURL:
            return "The Angy control-plane URL is invalid."
        case .invalidResponse:
            return "The Angy control plane returned an invalid response."
        case .server(let message):
            return message
        }
    }
}

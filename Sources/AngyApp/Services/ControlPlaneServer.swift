import AngyCore
import Foundation
import Network

enum AngyControlPlaneError: LocalizedError {
    case listenerFailed(String)
    case discoveryWriteFailed(Error)
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .listenerFailed(let message):
            return "Could not start the Angy control plane: \(message)"
        case .discoveryWriteFailed(let error):
            return "Could not write Angy control-plane discovery data: \(error.localizedDescription)"
        case .invalidRequest(let message):
            return "Invalid Angy control-plane request: \(message)"
        }
    }
}

private struct ControlPlaneDiscovery: Codable {
    let port: UInt16
    let token: String
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
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

private struct HateMailRequestBody: Codable {
    let force: Bool?
}

final class AngyControlPlaneServer {
    private let config: AppConfig
    private let token = UUID().uuidString.lowercased()
    private let queue = DispatchQueue(label: "AngyControlPlaneServer")
    private let handler: (AngyControlRequest) async -> AngyControlResponse
    private var listener: NWListener?

    init(
        config: AppConfig,
        handler: @escaping (AngyControlRequest) async -> AngyControlResponse
    ) {
        self.config = config
        self.handler = handler
    }

    func start() throws {
        guard listener == nil else {
            return
        }

        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(IPv4Address.loopback), port: .any)
        let listener = try NWListener(using: parameters)

        let semaphore = DispatchSemaphore(value: 0)
        var startupError: Error?

        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                do {
                    try self?.writeDiscoveryFile(port: listener.port)
                } catch {
                    startupError = error
                    listener.cancel()
                }
                semaphore.signal()
            case .failed(let error):
                startupError = AngyControlPlaneError.listenerFailed(error.localizedDescription)
                semaphore.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        listener.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + 5)

        if let startupError {
            throw startupError
        }

        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        try? FileManager.default.removeItem(at: discoveryFileURL())
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, accumulatedData: Data())
    }

    private func receive(on connection: NWConnection, accumulatedData: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                self.respond(
                    on: connection,
                    statusCode: 500,
                    response: AngyControlResponse(ok: false, message: error.localizedDescription)
                )
                return
            }

            var buffer = accumulatedData
            if let data {
                buffer.append(data)
            }

            if let request = self.parseRequest(from: buffer) {
                Task {
                    let (statusCode, response) = await self.route(request: request)
                    self.respond(on: connection, statusCode: statusCode, response: response)
                }
                return
            }

            if isComplete {
                self.respond(
                    on: connection,
                    statusCode: 400,
                    response: AngyControlResponse(ok: false, message: "Incomplete HTTP request.")
                )
                return
            }

            self.receive(on: connection, accumulatedData: buffer)
        }
    }

    private func parseRequest(from data: Data) -> HTTPRequest? {
        let headerDelimiter = Data("\r\n\r\n".utf8)
        guard let headerBytesRange = data.range(of: headerDelimiter),
              let headerText = String(data: data.subdata(in: 0..<headerBytesRange.lowerBound), encoding: .utf8) else {
            return nil
        }

        let headerLines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = headerLines.first else {
            return nil
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            let split = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard split.count == 2 else {
                continue
            }
            headers[split[0].trimmingCharacters(in: .whitespaces).lowercased()] =
                split[1].trimmingCharacters(in: .whitespaces)
        }

        let bodyStart = headerBytesRange.upperBound
        let body: Data

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let decodedBody = decodeChunkedBody(from: data, bodyStart: bodyStart) else {
                return nil
            }
            body = decodedBody
        } else {
            let contentLength = Int(headers["content-length"] ?? "0") ?? 0
            guard data.count >= bodyStart + contentLength else {
                return nil
            }
            body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        }
        return HTTPRequest(
            method: parts[0].uppercased(),
            path: parts[1],
            headers: headers,
            body: body
        )
    }

    private func decodeChunkedBody(from data: Data, bodyStart: Int) -> Data? {
        var cursor = bodyStart
        var decoded = Data()

        while true {
            guard let sizeLineEnd = data.range(of: Data("\r\n".utf8), in: cursor..<data.count) else {
                return nil
            }

            let sizeData = data.subdata(in: cursor..<sizeLineEnd.lowerBound)
            guard let sizeString = String(data: sizeData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  let chunkSize = Int(sizeString, radix: 16) else {
                return nil
            }

            let chunkStart = sizeLineEnd.upperBound
            let chunkEnd = chunkStart + chunkSize
            guard data.count >= chunkEnd + 2 else {
                return nil
            }

            if chunkSize == 0 {
                return decoded
            }

            decoded.append(data.subdata(in: chunkStart..<chunkEnd))
            cursor = chunkEnd + 2
        }
    }

    private func route(request: HTTPRequest) async -> (Int, AngyControlResponse) {
        guard request.headers["x-angy-token"] == token else {
            return (401, AngyControlResponse(ok: false, message: "Unauthorized."))
        }

        let pathComponents = request.path
            .split(separator: "/")
            .map(String.init)

        do {
            if request.method == "GET", pathComponents == ["v1", "windows"] {
                return (200, await handler(AngyControlRequest(action: .listWindows)))
            }

            if request.method == "GET", pathComponents == ["v1", "instances"] {
                return (200, await handler(AngyControlRequest(action: .listInstances)))
            }

            if request.method == "GET", pathComponents == ["v1", "settings"] {
                return (200, await handler(AngyControlRequest(action: .getSettings)))
            }

            if request.method == "POST", pathComponents == ["v1", "instances"] {
                let body = try decode(SpawnRequestBody.self, from: request.body)
                if body.frontmost == true {
                    return (200, await handler(AngyControlRequest(action: .spawnFrontmost)))
                }
                guard let windowID = body.windowID else {
                    throw AngyControlPlaneError.invalidRequest("windowID is required.")
                }
                return (200, await handler(AngyControlRequest(action: .spawnWindow, windowID: windowID)))
            }

            if request.method == "DELETE",
               pathComponents.count == 3,
               pathComponents[0] == "v1",
               pathComponents[1] == "instances" {
                return (200, await handler(instanceRequest(action: .removeInstance, from: pathComponents[2])))
            }

            if request.method == "POST",
               pathComponents.count == 4,
               pathComponents[0] == "v1",
               pathComponents[1] == "instances",
               pathComponents[3] == "pause" {
                return (200, await handler(instanceRequest(action: .pauseInstance, from: pathComponents[2])))
            }

            if request.method == "POST",
               pathComponents.count == 4,
               pathComponents[0] == "v1",
               pathComponents[1] == "instances",
               pathComponents[3] == "resume" {
                return (200, await handler(instanceRequest(action: .resumeInstance, from: pathComponents[2])))
            }

            if request.method == "POST",
               pathComponents.count == 4,
               pathComponents[0] == "v1",
               pathComponents[1] == "instances",
               pathComponents[3] == "target" {
                let body = try decode(RetargetRequestBody.self, from: request.body)
                var controlRequest = instanceRequest(action: .retargetInstance, from: pathComponents[2])
                controlRequest.windowID = body.windowID
                return (200, await handler(controlRequest))
            }

            if request.method == "POST",
               pathComponents.count == 4,
               pathComponents[0] == "v1",
               pathComponents[1] == "instances",
               pathComponents[3] == "override-state" {
                let body = try decode(OverrideStateBody.self, from: request.body)
                var controlRequest = instanceRequest(action: .setOverrideState, from: pathComponents[2])
                controlRequest.overrideState = body.state
                return (200, await handler(controlRequest))
            }

            if request.method == "DELETE",
               pathComponents.count == 4,
               pathComponents[0] == "v1",
               pathComponents[1] == "instances",
               pathComponents[3] == "override-state" {
                return (200, await handler(instanceRequest(action: .clearOverrideState, from: pathComponents[2])))
            }

            if request.method == "POST",
               pathComponents.count == 4,
               pathComponents[0] == "v1",
               pathComponents[1] == "instances",
               pathComponents[3] == "explode" {
                return (200, await handler(instanceRequest(action: .explodeInstance, from: pathComponents[2])))
            }

            if request.method == "POST",
               pathComponents.count == 4,
               pathComponents[0] == "v1",
               pathComponents[1] == "instances",
               pathComponents[3] == "hate-mail" {
                var controlRequest = instanceRequest(action: .writeHateMail, from: pathComponents[2])
                if !request.body.isEmpty {
                    let body = try decode(HateMailRequestBody.self, from: request.body)
                    controlRequest.force = body.force
                }
                return (200, await handler(controlRequest))
            }

            if request.method == "POST", pathComponents == ["v1", "settings"] {
                let body = try decode(SettingBody.self, from: request.body)
                return (200, await handler(AngyControlRequest(
                    action: .setSetting,
                    settingKey: body.key,
                    settingValue: body.value
                )))
            }

            return (404, AngyControlResponse(ok: false, message: "Unknown route."))
        } catch {
            return (400, AngyControlResponse(ok: false, message: error.localizedDescription))
        }
    }

    private func respond(on connection: NWConnection, statusCode: Int, response: AngyControlResponse) {
        let bodyData = (try? JSONEncoder().encode(response)) ?? Data()
        let header = [
            "HTTP/1.1 \(statusCode) \(statusText(for: statusCode))",
            "Content-Type: application/json",
            "Content-Length: \(bodyData.count)",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")

        var payload = Data(header.utf8)
        payload.append(bodyData)

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if data.isEmpty {
            throw AngyControlPlaneError.invalidRequest("Missing JSON body.")
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private func statusText(for statusCode: Int) -> String {
        switch statusCode {
        case 200:
            return "OK"
        case 400:
            return "Bad Request"
        case 401:
            return "Unauthorized"
        case 404:
            return "Not Found"
        default:
            return "Error"
        }
    }

    private func decodePath(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    private func instanceRequest(action: AngyControlAction, from pathValue: String) -> AngyControlRequest {
        let decodedValue = decodePath(pathValue)
        if decodedValue.hasPrefix("#") {
            return AngyControlRequest(action: action, instanceTag: decodedValue)
        }

        return AngyControlRequest(action: action, instanceID: AngyInstanceID(rawValue: decodedValue))
    }

    private func discoveryFileURL() -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        return root
            .appendingPathComponent("Angy", isDirectory: true)
            .appendingPathComponent("control-plane.json", isDirectory: false)
    }

    private func writeDiscoveryFile(port: NWEndpoint.Port?) throws {
        guard let port else {
            throw AngyControlPlaneError.listenerFailed("The listener did not publish a port.")
        }

        let fileURL = discoveryFileURL()
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let discovery = ControlPlaneDiscovery(port: port.rawValue, token: token)
            let data = try JSONEncoder().encode(discovery)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            throw AngyControlPlaneError.discoveryWriteFailed(error)
        }
    }
}

import AngyCore
import Foundation
import XCTest
@testable import Angy

final class HiveControlTests: XCTestCase {
    func testHateMailWriterRequiresFeatureToBeEnabled() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("angy-hate-mail-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let writer = HateMailWriter(baseDirectoryProvider: { tempDirectory })

        do {
            _ = try await writer.writeMail(
                for: makeSnapshot(id: "spawned-1", tag: "#1"),
                config: .live,
                enabled: false
            )
            XCTFail("Expected featureDisabled when hate mail is turned off.")
        } catch let error as HateMailWriterError {
            XCTAssertEqual(error.errorDescription, HateMailWriterError.featureDisabled.errorDescription)
        }
    }

    func testHateMailWriterWritesToConfiguredFolderAndAppliesCooldown() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("angy-hate-mail-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let writer = HateMailWriter(baseDirectoryProvider: { tempDirectory })
        let snapshot = makeSnapshot(id: "spawned-1", tag: "#1")

        var config = AppConfig.live
        config.hateMailCooldown = 60

        let fileURL = try await writer.writeMail(
            for: snapshot,
            config: config,
            enabled: true
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        let content = try String(contentsOf: fileURL)
        XCTAssertTrue(content.contains("Angy #1"))
        XCTAssertTrue(content.contains("Example / Build Logs"))
        XCTAssertTrue(content.contains("error, timeout"))

        do {
            _ = try await writer.writeMail(
                for: snapshot,
                config: config,
                enabled: true
            )
            XCTFail("Expected a cooldown error on the second write.")
        } catch let error as HateMailWriterError {
            guard case .coolingDown(let remaining) = error else {
                return XCTFail("Expected a coolingDown error.")
            }
            XCTAssertGreaterThan(remaining, 0)
            XCTAssertEqual(error.errorDescription, "This Angy is still cooling down. Try again in 1m.")
        }
    }

    func testHateMailWriterForceBypassesCooldown() async throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("angy-hate-mail-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let writer = HateMailWriter(baseDirectoryProvider: { tempDirectory })
        let snapshot = makeSnapshot(id: "spawned-1", tag: "#1")

        var config = AppConfig.live
        config.hateMailCooldown = 60

        _ = try await writer.writeMail(
            for: snapshot,
            config: config,
            enabled: true
        )

        do {
            _ = try await writer.writeMail(
                for: snapshot,
                config: config,
                enabled: true,
                force: true
            )
        } catch {
            XCTFail("Expected force=true to bypass cooldown, got \(error.localizedDescription)")
        }
    }

    func testControlPlaneRoutesForcedHateMailRequests() async throws {
        let recorder = RequestRecorder()
        let server = AngyControlPlaneServer(config: .live) { request in
            await recorder.record(request)
            return AngyControlResponse(ok: true, message: "wrote")
        }
        try server.start()
        defer { server.stop() }

        let discovery = try loadDiscovery()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(discovery.port)/v1/instances/%231/hate-mail")!)
        request.httpMethod = "POST"
        request.setValue(discovery.token, forHTTPHeaderField: "X-Angy-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = Data(#"{"force":true}"#.utf8)
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let decoded = try JSONDecoder().decode(AngyControlResponse.self, from: data)
        XCTAssertEqual(httpResponse.statusCode, 200, decoded.message ?? "no message")
        XCTAssertTrue(decoded.ok)

        let recordedRequest = await recorder.lastRequest
        XCTAssertEqual(recordedRequest?.action, .writeHateMail)
        XCTAssertEqual(recordedRequest?.instanceTag, "#1")
        XCTAssertEqual(recordedRequest?.force, true)
    }

    func testControlPlaneRejectsUnauthorizedRequests() async throws {
        let server = AngyControlPlaneServer(config: .live) { _ in
            AngyControlResponse(ok: true, message: "ok")
        }
        try server.start()
        defer { server.stop() }

        let discovery = try loadDiscovery()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(discovery.port)/v1/settings")!)
        request.httpMethod = "GET"

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(httpResponse.statusCode, 401)

        let decoded = try JSONDecoder().decode(AngyControlResponse.self, from: data)
        XCTAssertFalse(decoded.ok)
        XCTAssertEqual(decoded.message, "Unauthorized.")
    }

    func testControlPlaneRoutesSpawnWindowRequests() async throws {
        let recorder = RequestRecorder()
        let server = AngyControlPlaneServer(config: .live) { request in
            await recorder.record(request)
            return AngyControlResponse(ok: true, message: "spawned")
        }
        try server.start()
        defer { server.stop() }

        let discovery = try loadDiscovery()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(discovery.port)/v1/instances")!)
        request.httpMethod = "POST"
        request.setValue(discovery.token, forHTTPHeaderField: "X-Angy-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = Data(#"{"windowID":1234,"frontmost":false}"#.utf8)
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let decoded = try JSONDecoder().decode(AngyControlResponse.self, from: data)
        XCTAssertEqual(httpResponse.statusCode, 200, decoded.message ?? "no message")
        XCTAssertTrue(decoded.ok)

        let recordedRequest = await recorder.lastRequest
        XCTAssertNotNil(recordedRequest)
        XCTAssertEqual(recordedRequest?.action, .spawnWindow)
        XCTAssertEqual(recordedRequest?.windowID, 1234)
    }

    func testControlPlaneRoutesSpawnedTagAliases() async throws {
        let recorder = RequestRecorder()
        let server = AngyControlPlaneServer(config: .live) { request in
            await recorder.record(request)
            return AngyControlResponse(ok: true, message: "paused")
        }
        try server.start()
        defer { server.stop() }

        let discovery = try loadDiscovery()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(discovery.port)/v1/instances/%232/pause")!)
        request.httpMethod = "POST"
        request.setValue(discovery.token, forHTTPHeaderField: "X-Angy-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("0", forHTTPHeaderField: "Content-Length")
        request.httpBody = Data()

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let decoded = try JSONDecoder().decode(AngyControlResponse.self, from: data)
        XCTAssertEqual(httpResponse.statusCode, 200, decoded.message ?? "no message")
        XCTAssertTrue(decoded.ok)

        let recordedRequest = await recorder.lastRequest
        XCTAssertEqual(recordedRequest?.action, .pauseInstance)
        XCTAssertEqual(recordedRequest?.instanceTag, "#2")
        XCTAssertNil(recordedRequest?.instanceID)
    }

    func testControlPlaneRoutesSettingsMutations() async throws {
        let recorder = RequestRecorder()
        let server = AngyControlPlaneServer(config: .live) { request in
            await recorder.record(request)
            return AngyControlResponse(ok: true, message: "updated")
        }
        try server.start()
        defer { server.stop() }

        let discovery = try loadDiscovery()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(discovery.port)/v1/settings")!)
        request.httpMethod = "POST"
        request.setValue(discovery.token, forHTTPHeaderField: "X-Angy-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = Data(#"{"key":"hateMailEnabled","value":"true"}"#.utf8)
        request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = try XCTUnwrap(response as? HTTPURLResponse)
        let decoded = try JSONDecoder().decode(AngyControlResponse.self, from: data)
        XCTAssertEqual(httpResponse.statusCode, 200, decoded.message ?? "no message")
        XCTAssertTrue(decoded.ok)

        let recordedRequest = await recorder.lastRequest
        XCTAssertEqual(recordedRequest?.action, .setSetting)
        XCTAssertEqual(recordedRequest?.settingKey, "hateMailEnabled")
        XCTAssertEqual(recordedRequest?.settingValue, "true")
    }

    private func loadDiscovery() throws -> ControlPlaneDiscoveryFile {
        let fileURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Angy", isDirectory: true)
            .appendingPathComponent("control-plane.json", isDirectory: false)
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(ControlPlaneDiscoveryFile.self, from: data)
    }
}

private func makeSnapshot(id: String, tag: String) -> AngyInstanceSnapshot {
    AngyInstanceSnapshot(
        id: AngyInstanceID(rawValue: id),
        role: .spawned,
        tag: tag,
        target: AngyWindowRef(
            windowID: 42,
            bundleID: "com.example.app",
            appName: "Example",
            title: "Build Logs",
            frame: AngyRect(x: 10, y: 20, width: 300, height: 400),
            isVisible: true,
            isFocused: false
        ),
        emotion: .furious,
        activity: .blocked,
        angerScore: 99,
        paused: false,
        effectPhase: "exploding",
        quip: "excellent. another fire.",
        matchedTriggers: ["error", "timeout"]
    )
}

private actor RequestRecorder {
    private(set) var lastRequest: AngyControlRequest?

    func record(_ request: AngyControlRequest) {
        lastRequest = request
    }
}

private struct ControlPlaneDiscoveryFile: Codable {
    let port: UInt16
    let token: String
}

import AngyCore
import CoreGraphics
import XCTest
@testable import Angy

@MainActor
final class PresentationBehaviorTests: XCTestCase {
    func testRageMeterBandThresholds() {
        XCTAssertEqual(RageMeterBand.band(for: 0), .calm)
        XCTAssertEqual(RageMeterBand.band(for: 24), .calm)
        XCTAssertEqual(RageMeterBand.band(for: 25), .curious)
        XCTAssertEqual(RageMeterBand.band(for: 44), .curious)
        XCTAssertEqual(RageMeterBand.band(for: 45), .annoyed)
        XCTAssertEqual(RageMeterBand.band(for: 69), .annoyed)
        XCTAssertEqual(RageMeterBand.band(for: 70), .furious)
        XCTAssertEqual(RageMeterBand.band(for: 94), .furious)
        XCTAssertEqual(RageMeterBand.band(for: 95), .critical)
    }

    func testExplosionMonitorRequiresSustainedCriticalRage() {
        var monitor = ExplosionMonitor(config: .live)
        let start = Date(timeIntervalSinceReferenceDate: 100)

        XCTAssertFalse(
            monitor.shouldExplode(
                emotion: .furious,
                angerScore: 95,
                now: start
            )
        )
        XCTAssertFalse(
            monitor.shouldExplode(
                emotion: .furious,
                angerScore: 95,
                now: start.addingTimeInterval(2.9)
            )
        )
        XCTAssertTrue(
            monitor.shouldExplode(
                emotion: .furious,
                angerScore: 95,
                now: start.addingTimeInterval(3.0)
            )
        )
    }

    func testExplosionMonitorCooldownBlocksImmediateRetrigger() {
        var monitor = ExplosionMonitor(config: .live)
        let start = Date(timeIntervalSinceReferenceDate: 200)

        _ = monitor.shouldExplode(emotion: .furious, angerScore: 95, now: start)
        XCTAssertTrue(
            monitor.shouldExplode(
                emotion: .furious,
                angerScore: 95,
                now: start.addingTimeInterval(3.0)
            )
        )

        monitor.startCooldown(now: start.addingTimeInterval(6.0))

        XCTAssertFalse(
            monitor.shouldExplode(
                emotion: .furious,
                angerScore: 95,
                now: start.addingTimeInterval(20.0)
            )
        )
        XCTAssertFalse(
            monitor.shouldExplode(
                emotion: .furious,
                angerScore: 95,
                now: start.addingTimeInterval(25.0)
            )
        )
        XCTAssertFalse(
            monitor.shouldExplode(
                emotion: .furious,
                angerScore: 95,
                now: start.addingTimeInterval(26.1)
            )
        )
        XCTAssertTrue(
            monitor.shouldExplode(
                emotion: .furious,
                angerScore: 95,
                now: start.addingTimeInterval(29.2)
            )
        )
    }

    func testSoundEventsOnlyFireOnTransitions() {
        let blocked = makePresentation(
            emotion: .annoyed,
            activity: .blocked,
            anger: 52,
            effectPhase: .alive
        )

        XCTAssertEqual(
            OverlaySoundEventDetector.events(from: nil, to: blocked, didExplode: false),
            [.blocked]
        )
        XCTAssertEqual(
            OverlaySoundEventDetector.events(from: blocked, to: blocked, didExplode: false),
            []
        )
    }

    func testSoundPlayerHonorsDisableFlag() {
        var config = AppConfig.live
        config.soundEnabled = false
        let backend = RecordingSoundBackend()
        let player = SoundEffectPlayer(config: config, backend: backend)

        player.play(.blocked)

        XCTAssertTrue(backend.systemSoundNames.isEmpty)
        XCTAssertEqual(backend.beepCount, 0)
    }

    func testSoundPlayerFallsBackToSystemSounds() {
        let backend = RecordingSoundBackend()
        let player = SoundEffectPlayer(config: .live, backend: backend)

        player.play(.explode)

        XCTAssertEqual(backend.systemSoundNames, ["Glass"])
        XCTAssertEqual(backend.beepCount, 0)
    }

    func testASCIIStickerRendererPreservesVerticalOrientation() async throws {
        let sourceImage = try XCTUnwrap(makeVerticalSplitImage(width: 20, height: 20))
        let assetSource = StickerAssetSource.rasterFrames([
            StickerFrameAsset(
                image: StickerImage(cgImage: sourceImage),
                duration: 1.0 / 12.0,
                cacheKey: "orientation-regression",
                sourceURL: nil,
                skipBackgroundRemoval: false
            )
        ])

        let renderedSequence = await ASCIIStickerRenderer.shared.renderSequence(from: assetSource)
        let renderedImage = try XCTUnwrap(renderedSequence?.firstFrame?.image.cgImage)

        let topColor = try XCTUnwrap(samplePixel(in: renderedImage, x: renderedImage.width / 2, yFromTop: 1))
        let bottomColor = try XCTUnwrap(samplePixel(in: renderedImage, x: renderedImage.width / 2, yFromTop: renderedImage.height - 2))

        XCTAssertGreaterThan(topColor.red, topColor.blue, "Expected the top of the rendered sticker to remain red")
        XCTAssertGreaterThan(bottomColor.blue, bottomColor.red, "Expected the bottom of the rendered sticker to remain blue")
    }

    func testOverlayFrameAppliesManualDragOffset() {
        let frame = OverlayFrameCalculator.frame(
            windowFrame: CGRect(x: 100, y: 200, width: 800, height: 600),
            overlaySize: CGSize(width: 120, height: 140),
            baseOffset: CGSize(width: 80, height: 14),
            userOffset: CGSize(width: 160, height: -90),
            padding: 14,
            screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000)
        )

        XCTAssertEqual(frame.origin.x, 340)
        XCTAssertEqual(frame.origin.y, 640)
    }

    func testOverlayFrameClampsDraggedPositionInsideScreenBounds() {
        let frame = OverlayFrameCalculator.frame(
            windowFrame: CGRect(x: 100, y: 200, width: 800, height: 600),
            overlaySize: CGSize(width: 120, height: 140),
            baseOffset: CGSize(width: 80, height: 14),
            userOffset: CGSize(width: -400, height: -900),
            padding: 14,
            screenFrame: CGRect(x: 0, y: 0, width: 500, height: 400)
        )

        XCTAssertEqual(frame.origin.x, 14)
        XCTAssertEqual(frame.origin.y, 14)
    }

    private func makePresentation(
        emotion: CompanionState,
        activity: SessionActivityState,
        anger: Double,
        effectPhase: OverlayEffectPhase
    ) -> OverlayPresentationState {
        OverlayPresentationState(
            emotion: emotion,
            activity: activity,
            angerScore: anger,
            stickerName: "happy",
            quip: nil,
            effectPhase: effectPhase
        )
    }

    private func makeVerticalSplitImage(width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(red: 0.95, green: 0.15, blue: 0.18, alpha: 1))
        context.fill(CGRect(x: 0, y: height / 2, width: width, height: height / 2))
        context.setFillColor(CGColor(red: 0.12, green: 0.28, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height / 2))
        return context.makeImage()
    }

    private func samplePixel(in cgImage: CGImage, x: Int, yFromTop: Int) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8)? {
        let width = cgImage.width
        let height = cgImage.height
        guard x >= 0, x < width, yFromTop >= 0, yFromTop < height else {
            return nil
        }

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)

        let rendered = bytes.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else {
                return false
            }

            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }

        guard rendered else {
            return nil
        }

        let offset = ((yFromTop * width) + x) * 4
        return (
            red: bytes[offset],
            green: bytes[offset + 1],
            blue: bytes[offset + 2],
            alpha: bytes[offset + 3]
        )
    }
}

private final class RecordingSoundBackend: SoundPlaybackBackend {
    private(set) var resourceURLs: [URL] = []
    private(set) var systemSoundNames: [String] = []
    private(set) var beepCount = 0

    func playResource(at url: URL) -> Bool {
        resourceURLs.append(url)
        return false
    }

    func playSystemSound(named name: String) -> Bool {
        systemSoundNames.append(name)
        return true
    }

    func beep() {
        beepCount += 1
    }
}

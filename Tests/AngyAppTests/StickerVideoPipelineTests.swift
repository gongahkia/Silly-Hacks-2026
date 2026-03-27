import AppKit
import XCTest
@testable import Angy

@MainActor
final class StickerVideoPipelineTests: XCTestCase {
    func testOverlayAssetsDefaultWebMCanRenderAnimatedASCIISequence() async throws {
        _ = NSApplication.shared

        guard WebVideoStickerDecoder.isFFmpegAvailable else {
            throw XCTSkip("ffmpeg is not installed; WebKit on this machine does not load the local WebM")
        }

        guard let assetSource = CompanionPersona.assetSource(for: "happy") else {
            XCTFail("Expected a sticker asset source for the fallback happy sticker")
            return
        }

        let resolvedVideoAsset: StickerVideoAsset

        switch assetSource {
        case .video(let videoAsset):
            resolvedVideoAsset = videoAsset
            XCTAssertEqual(videoAsset.sourceURL.lastPathComponent, "default.webm")
            XCTAssertTrue(videoAsset.sourceURL.path.contains("/overlay-assets/"))
        case .rasterFrames:
            XCTFail("Expected the overlay-assets default WebM fallback to be selected")
            return
        }

        let decodedFrames = await WebVideoStickerDecoder.shared.decodeFrames(from: resolvedVideoAsset)
        XCTAssertGreaterThan(
            decodedFrames.count,
            1,
            WebVideoStickerDecoder.shared.lastFailureReason ?? "video decoder returned no frames"
        )
        XCTAssertTrue(
            frameHasVisiblePixels(decodedFrames.first?.image.cgImage),
            "Expected the first decoded video frame to retain visible non-transparent pixels"
        )

        let renderedSequence = await ASCIIStickerRenderer.shared.renderSequence(from: assetSource)

        XCTAssertNotNil(
            renderedSequence,
            WebVideoStickerDecoder.shared.lastFailureReason ?? "ASCII renderer returned nil"
        )
        XCTAssertGreaterThan(
            renderedSequence?.frames.count ?? 0,
            1,
            WebVideoStickerDecoder.shared.lastFailureReason ?? "ASCII renderer produced no frames"
        )
        XCTAssertGreaterThan(renderedSequence?.layoutSize.width ?? 0, 0)
        XCTAssertGreaterThan(renderedSequence?.layoutSize.height ?? 0, 0)
        XCTAssertTrue(
            renderedSequence.map(firstFrameHasVisiblePixels) ?? false,
            "Expected the first rendered frame to retain visible non-transparent pixels"
        )
    }

    private func firstFrameHasVisiblePixels(_ sequence: RenderedASCIIStickerSequence) -> Bool {
        frameHasVisiblePixels(sequence.firstFrame?.image.cgImage)
    }

    private func frameHasVisiblePixels(_ cgImage: CGImage?) -> Bool {
        guard let cgImage else { return false }

        let width = cgImage.width
        let height = cgImage.height
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
            return false
        }

        return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 }
    }
}

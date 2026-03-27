import CoreGraphics
import Foundation
import ImageIO
import WebKit

@MainActor
final class WebVideoStickerDecoder: NSObject {
    static let shared = WebVideoStickerDecoder()

    static var isFFmpegAvailable: Bool {
        (try? FFmpegToolchain.resolve()) != nil
    }

    private static let bootstrapHTML = #"""
    <!doctype html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <style>
        html, body {
          margin: 0;
          padding: 0;
          background: transparent;
        }
      </style>
    </head>
    <body>
      <script>
        window.decodeStickerVideo = async function(videoDataURL, maxFrames, maxWidth, targetFPS) {
          const loadVideo = (src) => new Promise((resolve, reject) => {
            const video = document.createElement('video');
            let settled = false;
            const timeout = window.setTimeout(() => {
              if (settled) { return; }
              settled = true;
              reject(new Error('video_load_timeout'));
            }, 10000);

            const cleanup = () => {
              window.clearTimeout(timeout);
              video.removeEventListener('loadedmetadata', handleLoaded);
              video.removeEventListener('loadeddata', handleLoaded);
              video.removeEventListener('error', handleError);
            };

            const handleLoaded = () => {
              if (settled) { return; }
              if ((video.videoWidth || 0) <= 0 || (video.videoHeight || 0) <= 0) { return; }
              settled = true;
              cleanup();
              video.pause();
              resolve(video);
            };

            const handleError = () => {
              if (settled) { return; }
              settled = true;
              cleanup();
              reject(new Error('video_load_failed'));
            };

            video.muted = true;
            video.playsInline = true;
            video.preload = 'auto';
            video.loop = false;
            video.addEventListener('loadedmetadata', handleLoaded);
            video.addEventListener('loadeddata', handleLoaded);
            video.addEventListener('error', handleError);
            video.src = src;
            video.load();
          });

          const waitForSeek = (video, targetTime) => new Promise((resolve, reject) => {
            if (!Number.isFinite(targetTime)) {
              resolve();
              return;
            }

            if (Math.abs(video.currentTime - targetTime) < 0.001) {
              window.requestAnimationFrame(() => resolve());
              return;
            }

            let settled = false;
            const timeout = window.setTimeout(() => {
              if (settled) { return; }
              settled = true;
              cleanup();
              reject(new Error('video_seek_timeout'));
            }, 5000);

            const cleanup = () => {
              window.clearTimeout(timeout);
              video.removeEventListener('seeked', handleSeeked);
              video.removeEventListener('error', handleError);
            };

            const handleSeeked = () => {
              if (settled) { return; }
              settled = true;
              cleanup();
              window.requestAnimationFrame(() => resolve());
            };

            const handleError = () => {
              if (settled) { return; }
              settled = true;
              cleanup();
              reject(new Error('video_seek_failed'));
            };

            video.addEventListener('seeked', handleSeeked, { once: true });
            video.addEventListener('error', handleError, { once: true });
            video.currentTime = targetTime;
          });

          const video = await loadVideo(videoDataURL);
          const sourceWidth = Math.max(video.videoWidth || 1, 1);
          const sourceHeight = Math.max(video.videoHeight || 1, 1);
          const scale = sourceWidth > maxWidth ? (maxWidth / sourceWidth) : 1;
          const width = Math.max(1, Math.round(sourceWidth * scale));
          const height = Math.max(1, Math.round(sourceHeight * scale));
          const duration = Number.isFinite(video.duration) && video.duration > 0 ? video.duration : 0;
          const frameCount = duration > 0
            ? Math.max(1, Math.min(maxFrames, Math.max(1, Math.round(duration * targetFPS))))
            : 1;
          const frameDuration = duration > 0
            ? duration / frameCount
            : (1 / Math.max(targetFPS, 1));

          const canvas = document.createElement('canvas');
          canvas.width = width;
          canvas.height = height;
          const context = canvas.getContext('2d', { alpha: true, willReadFrequently: false });
          if (!context) {
            throw new Error('canvas_context_unavailable');
          }

          const frames = [];
          for (let index = 0; index < frameCount; index += 1) {
            const sampleTime = duration > 0
              ? Math.min(Math.max(index * frameDuration, 0), Math.max(duration - 0.001, 0))
              : 0;
            await waitForSeek(video, sampleTime);
            context.clearRect(0, 0, width, height);
            context.drawImage(video, 0, 0, width, height);
            frames.push({
              dataURL: canvas.toDataURL('image/png'),
              duration: frameDuration
            });
          }

          video.removeAttribute('src');
          video.load();

          return {
            width: sourceWidth,
            height: sourceHeight,
            duration: duration,
            frames: frames
          };
        };
      </script>
    </body>
    </html>
    """#

    private let webView: WKWebView
    private var renderedFramesCache: [String: [StickerFrameAsset]] = [:]
    private var pageLoadTask: Task<Void, Error>?
    private var navigationDelegateProxy: NavigationDelegateProxy?
    private(set) var lastFailureReason: String?
    private let debugEnabled = ProcessInfo.processInfo.environment["ANGY_DEBUG"] == "1"

    private override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), configuration: configuration)
        super.init()
    }

    func decodeFrames(from asset: StickerVideoAsset) async -> [StickerFrameAsset] {
        if let cached = renderedFramesCache[asset.cacheKey] {
            if debugEnabled {
                print("[AngyWebVideoDecoder] cache-hit key=\(asset.cacheKey) frames=\(cached.count)")
            }
            return cached
        }

        lastFailureReason = nil
        if debugEnabled {
            print("[AngyWebVideoDecoder] decode start path=\(asset.sourceURL.path)")
        }

        let ffmpegFrames = await decodeFramesWithFFmpeg(from: asset)
        if !ffmpegFrames.isEmpty {
            renderedFramesCache[asset.cacheKey] = ffmpegFrames
            if debugEnabled {
                print("[AngyWebVideoDecoder] decode finished via=ffmpeg frames=\(ffmpegFrames.count)")
            }
            return ffmpegFrames
        }

        let webKitFrames = await decodeFramesWithWebKit(from: asset)
        if !webKitFrames.isEmpty {
            renderedFramesCache[asset.cacheKey] = webKitFrames
            if debugEnabled {
                print("[AngyWebVideoDecoder] decode finished via=webkit frames=\(webKitFrames.count)")
            }
            return webKitFrames
        }

        if debugEnabled {
            print("[AngyWebVideoDecoder] decode failed path=\(asset.sourceURL.path) reason=\(lastFailureReason ?? "unknown")")
        }

        return []
    }

    private func decodeFramesWithWebKit(from asset: StickerVideoAsset) async -> [StickerFrameAsset] {
        do {
            try await ensureDecoderPageLoaded()

            let result = try await webView.callAsyncJavaScript(
                "return await window.decodeStickerVideo(videoDataURL, maxFrames, maxWidth, targetFPS);",
                arguments: [
                    "videoDataURL": try videoDataURL(for: asset),
                    "maxFrames": 48,
                    "maxWidth": 256,
                    "targetFPS": 12
                ],
                in: nil,
                contentWorld: .page
            )

            let frames = parseFrames(from: result, asset: asset)
            if frames.isEmpty, lastFailureReason == nil {
                lastFailureReason = "video_decode_returned_no_frames"
            }

            return frames
        } catch {
            lastFailureReason = "webkit:\(String(describing: error))"
            print("[AngyWebVideoDecoder] webkit failed path=\(asset.sourceURL.path) error=\(error)")
            return []
        }
    }

    private func decodeFramesWithFFmpeg(from asset: StickerVideoAsset) async -> [StickerFrameAsset] {
        do {
            let sourceURL = asset.sourceURL
            if debugEnabled {
                print("[AngyWebVideoDecoder] ffmpeg extract start path=\(sourceURL.path)")
            }
            let extraction = try await Task.detached(priority: .userInitiated) {
                try FFmpegExtraction.extractFrames(
                    from: sourceURL
                )
            }.value

            defer {
                try? FileManager.default.removeItem(at: extraction.workingDirectory)
            }

            guard !extraction.frameURLs.isEmpty else {
                lastFailureReason = "ffmpeg:extracted_no_frames"
                return []
            }

            let frameDuration = max(
                1.0 / 30.0,
                extraction.totalDuration.map { $0 / Double(extraction.frameURLs.count) } ?? (1.0 / 12.0)
            )

            let frames = await Task.detached(priority: .userInitiated) { () -> [StickerFrameAsset] in
                extraction.frameURLs.compactMap { frameURL in
                    guard let cgImage = loadCGImage(from: frameURL) else {
                        return nil
                    }

                    return StickerFrameAsset(
                        image: StickerImage(cgImage: cgImage),
                        duration: frameDuration,
                        cacheKey: "\(asset.cacheKey)#ffmpeg:\(frameURL.lastPathComponent)",
                        sourceURL: asset.sourceURL,
                        skipBackgroundRemoval: true
                    )
                }
            }.value

            if frames.isEmpty {
                lastFailureReason = "ffmpeg:png_decode_failed"
            }

            if debugEnabled {
                print("[AngyWebVideoDecoder] ffmpeg extract finished path=\(sourceURL.path) frames=\(frames.count)")
            }

            return frames
        } catch {
            lastFailureReason = "ffmpeg:\(error)"
            print("[AngyWebVideoDecoder] ffmpeg failed path=\(asset.sourceURL.path) error=\(error)")
            return []
        }
    }

    private func ensureDecoderPageLoaded() async throws {
        if let pageLoadTask {
            return try await pageLoadTask.value
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            try await self.loadDecoderPage()
        }
        pageLoadTask = task

        do {
            try await task.value
        } catch {
            pageLoadTask = nil
            throw error
        }
    }

    private func loadDecoderPage() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let navigationDelegate = NavigationDelegateProxy(continuation: continuation)
            navigationDelegateProxy = navigationDelegate
            webView.navigationDelegate = navigationDelegate
            webView.loadHTMLString(Self.bootstrapHTML, baseURL: nil)
        }
    }

    private func videoDataURL(for asset: StickerVideoAsset) throws -> String {
        let data = try Data(contentsOf: asset.sourceURL)
        return "data:\(asset.mimeType);base64,\(data.base64EncodedString())"
    }

    private func parseFrames(from result: Any?, asset: StickerVideoAsset) -> [StickerFrameAsset] {
        guard let dictionary = result as? [String: Any],
              let frameDictionaries = dictionary["frames"] as? [[String: Any]] else {
            lastFailureReason = "unexpected_js_result:\(String(describing: result))"
            return []
        }

        var frames: [StickerFrameAsset] = []
        frames.reserveCapacity(frameDictionaries.count)

        for (index, frameDictionary) in frameDictionaries.enumerated() {
            guard let dataURL = frameDictionary["dataURL"] as? String,
                  let cgImage = cgImage(fromDataURL: dataURL) else {
                continue
            }

            let duration = max(
                1.0 / 30.0,
                frameDictionary["duration"] as? Double ?? (1.0 / 12.0)
            )

            frames.append(
                StickerFrameAsset(
                    image: StickerImage(cgImage: cgImage),
                    duration: duration,
                    cacheKey: "\(asset.cacheKey)#\(index)",
                    sourceURL: asset.sourceURL,
                    skipBackgroundRemoval: false
                )
            )
        }

        if frames.isEmpty {
            lastFailureReason = "js_frames_present_but_image_decode_failed"
        }

        return frames
    }

    private func cgImage(fromDataURL dataURL: String) -> CGImage? {
        guard let commaIndex = dataURL.firstIndex(of: ",") else {
            return nil
        }

        let encoded = String(dataURL[dataURL.index(after: commaIndex)...])
        guard let data = Data(base64Encoded: encoded) else {
            return nil
        }

        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }

        return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }
}

@MainActor
private final class NavigationDelegateProxy: NSObject, WKNavigationDelegate {
    private let continuation: CheckedContinuation<Void, Error>
    private var hasResumed = false

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        resume(with: .success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        resume(with: .failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        resume(with: .failure(error))
    }

    private func resume(with result: Result<Void, Error>) {
        guard !hasResumed else { return }
        hasResumed = true
        continuation.resume(with: result)
    }
}

private struct FFmpegExtraction: Sendable {
    let workingDirectory: URL
    let frameURLs: [URL]
    let totalDuration: Double?

    static func extractFrames(from sourceURL: URL) throws -> FFmpegExtraction {
        let toolchain = try FFmpegToolchain.resolve()
        let fileManager = FileManager.default
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("angy-webm-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)

        let outputPattern = workingDirectory.appendingPathComponent("frame_%04d.png")
        let ffmpegArguments = [
            "-nostdin",
            "-hide_banner",
            "-loglevel", "error",
            "-i", sourceURL.path,
            "-an",
            "-vf", "fps=12,colorkey=0x000000:0.12:0.04,format=rgba",
            "-frames:v", "48",
            "-pix_fmt", "rgba",
            "-y",
            outputPattern.path
        ]

        try runProcess(
            executableURL: toolchain.ffmpeg,
            arguments: ffmpegArguments,
            captureOutput: false
        )

        let frameURLs = try fileManager.contentsOfDirectory(
            at: workingDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.lowercased() == "png" }
        .sorted { lhs, rhs in
            lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
        }

        let totalDuration = try? probeDuration(
            executableURL: toolchain.ffprobe,
            sourceURL: sourceURL
        )

        return FFmpegExtraction(
            workingDirectory: workingDirectory,
            frameURLs: frameURLs,
            totalDuration: totalDuration
        )
    }

    private static func probeDuration(executableURL: URL, sourceURL: URL) throws -> Double {
        let output = try runProcess(
            executableURL: executableURL,
            arguments: [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                sourceURL.path
            ]
        )
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let duration = Double(trimmed), duration > 0 else {
            throw FFmpegDecoderError.invalidDurationOutput(trimmed)
        }
        return duration
    }

    @discardableResult
    private static func runProcess(
        executableURL: URL,
        arguments: [String],
        captureOutput: Bool = true
    ) throws -> String {
        let process = Process()

        process.executableURL = executableURL
        process.arguments = arguments

        let outputPipe: Pipe?
        let errorPipe: Pipe?

        if captureOutput {
            let createdOutputPipe = Pipe()
            let createdErrorPipe = Pipe()
            outputPipe = createdOutputPipe
            errorPipe = createdErrorPipe
            process.standardOutput = createdOutputPipe
            process.standardError = createdErrorPipe
        } else {
            outputPipe = nil
            errorPipe = nil
        }

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        let errorData = errorPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw FFmpegDecoderError.processFailed(
                executable: executableURL.lastPathComponent,
                status: process.terminationStatus,
                output: errorOutput.isEmpty ? output : errorOutput
            )
        }

        return output
    }
}

private func loadCGImage(from url: URL) -> CGImage? {
    guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
        return nil
    }

    return rasterizedCopy(of: image)
}

private func rasterizedCopy(of image: CGImage) -> CGImage? {
    let width = image.width
    let height = image.height

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

    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

private struct FFmpegToolchain: Sendable {
    let ffmpeg: URL
    let ffprobe: URL

    static func resolve() throws -> FFmpegToolchain {
        guard let ffmpeg = executableURL(named: "ffmpeg"),
              let ffprobe = executableURL(named: "ffprobe") else {
            throw FFmpegDecoderError.toolchainUnavailable
        }

        return FFmpegToolchain(ffmpeg: ffmpeg, ffprobe: ffprobe)
    }

    private static func executableURL(named name: String) -> URL? {
        let pathComponents = (
            ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init)
            ?? []
        ) + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]

        var seen: Set<String> = []

        for pathComponent in pathComponents {
            let candidate = URL(fileURLWithPath: pathComponent, isDirectory: true)
                .appendingPathComponent(name, isDirectory: false)
            let standardizedPath = candidate.standardizedFileURL.path
            guard seen.insert(standardizedPath).inserted else {
                continue
            }

            guard FileManager.default.isExecutableFile(atPath: standardizedPath) else {
                continue
            }

            return candidate
        }

        return nil
    }
}

private enum FFmpegDecoderError: LocalizedError {
    case toolchainUnavailable
    case processFailed(executable: String, status: Int32, output: String)
    case invalidDurationOutput(String)

    var errorDescription: String? {
        switch self {
        case .toolchainUnavailable:
            return "ffmpeg and ffprobe are not available on PATH"
        case .processFailed(let executable, let status, let output):
            return "\(executable) failed with status \(status): \(output)"
        case .invalidDurationOutput(let output):
            return "ffprobe returned an invalid duration: \(output)"
        }
    }
}

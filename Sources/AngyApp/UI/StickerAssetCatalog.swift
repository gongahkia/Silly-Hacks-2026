import CoreGraphics
import Foundation
import ImageIO

struct StickerImage: @unchecked Sendable {
    let cgImage: CGImage
}

struct StickerFrameAsset: Sendable {
    let image: StickerImage
    let duration: TimeInterval
    let cacheKey: String
    let sourceURL: URL?
    let skipBackgroundRemoval: Bool
}

struct StickerVideoAsset: Sendable {
    let sourceURL: URL
    let cacheKey: String
    let mimeType: String
}

enum StickerAssetSource: Sendable {
    case rasterFrames([StickerFrameAsset])
    case video(StickerVideoAsset)

    var cacheKey: String {
        switch self {
        case .rasterFrames(let frames):
            return frames.map(\.cacheKey).joined(separator: "|")
        case .video(let asset):
            return asset.cacheKey
        }
    }

    var sourceURL: URL? {
        switch self {
        case .rasterFrames(let frames):
            return frames.first?.sourceURL
        case .video(let asset):
            return asset.sourceURL
        }
    }
}

enum StickerAssetCatalog {
    private static let supportedRasterExtensions = ["png", "jpg", "jpeg", "gif", "webp", "tiff", "bmp"]
    private static let supportedVideoExtensions = ["webm", "mp4", "mov", "m4v"]
    private static let defaultSequenceFrameDuration = 1.0 / 12.0

    static func asset(named stickerName: String) -> StickerAssetSource? {
        if let folderAsset = loadAssetFromConfiguredFolders(named: stickerName) {
            return folderAsset
        }

        return bundledAsset(named: stickerName)
    }

    static func frames(for stickerName: String) -> [StickerFrameAsset] {
        guard case .rasterFrames(let frames) = asset(named: stickerName) else {
            return []
        }
        return frames
    }

    private static func loadAssetFromConfiguredFolders(named stickerName: String) -> StickerAssetSource? {
        for root in searchRoots() {
            if let asset = asset(in: root, matching: stickerName) {
                return asset
            }

            if let fallbackAsset = asset(in: root, matching: "default") {
                return fallbackAsset
            }

            if let singletonAsset = singletonAsset(in: root) {
                return singletonAsset
            }
        }

        return nil
    }

    private static func searchRoots() -> [URL] {
        let fileManager = FileManager.default
        var roots: [URL] = []

        if let override = ProcessInfo.processInfo.environment["ANGY_OVERLAY_ASSETS"], !override.isEmpty {
            roots.append(URL(fileURLWithPath: override, isDirectory: true))
        }

        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        roots.append(cwd)
        roots.append(cwd.appendingPathComponent("overlay-assets", isDirectory: true))
        roots.append(cwd.appendingPathComponent("gif", isDirectory: true))

        var deduplicated: [URL] = []
        var seen: Set<String> = []

        for root in roots {
            let standardized = root.standardizedFileURL.path
            guard seen.insert(standardized).inserted else { continue }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardized, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            deduplicated.append(root)
        }

        return deduplicated
    }

    private static func asset(in root: URL, matching name: String) -> StickerAssetSource? {
        if let subdirectoryFrames = loadFramesFromSubdirectory(root: root, name: name),
           !subdirectoryFrames.isEmpty {
            return .rasterFrames(subdirectoryFrames)
        }

        if let rasterAsset = loadSingleRasterFile(root: root, name: name) {
            return rasterAsset
        }

        if let videoAsset = loadSingleVideoFile(root: root, name: name) {
            return videoAsset
        }

        return nil
    }

    private static func loadFramesFromSubdirectory(root: URL, name: String) -> [StickerFrameAsset]? {
        let folderURL = root.appendingPathComponent(name, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }

        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let frameURLs = urls
            .filter { supportedRasterExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }

        var frames: [StickerFrameAsset] = []

        for frameURL in frameURLs {
            let decodedFrames = rasterFrames(
                from: frameURL,
                defaultFrameDuration: defaultSequenceFrameDuration
            )
            frames.append(contentsOf: decodedFrames)
        }

        return frames.isEmpty ? nil : frames
    }

    private static func loadSingleRasterFile(root: URL, name: String) -> StickerAssetSource? {
        for fileExtension in supportedRasterExtensions {
            let url = root.appendingPathComponent("\(name).\(fileExtension)", isDirectory: false)
            let frames = rasterFrames(from: url, defaultFrameDuration: defaultSequenceFrameDuration)
            if !frames.isEmpty {
                return .rasterFrames(frames)
            }
        }

        return nil
    }

    private static func loadSingleVideoFile(root: URL, name: String) -> StickerAssetSource? {
        for fileExtension in supportedVideoExtensions {
            let url = root.appendingPathComponent("\(name).\(fileExtension)", isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else {
                continue
            }

            return .video(
                StickerVideoAsset(
                    sourceURL: url,
                    cacheKey: fileSignature(for: url),
                    mimeType: mimeType(forVideoExtension: fileExtension)
                )
            )
        }

        return nil
    }

    private static func bundledAsset(named stickerName: String) -> StickerAssetSource? {
        let bundle = Bundle.module

        for fileExtension in supportedRasterExtensions {
            let directURL = bundle.url(forResource: stickerName, withExtension: fileExtension)
            let nestedURL = bundle.url(forResource: stickerName, withExtension: fileExtension, subdirectory: "Stickers")

            if let url = directURL ?? nestedURL {
                let frames = rasterFrames(from: url, defaultFrameDuration: defaultSequenceFrameDuration)
                if !frames.isEmpty {
                    return .rasterFrames(frames)
                }
            }
        }

        return nil
    }

    private static func singletonAsset(in root: URL) -> StickerAssetSource? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let candidateURLs = urls
            .filter { !$0.hasDirectoryPath }
            .filter {
                let fileExtension = $0.pathExtension.lowercased()
                return supportedRasterExtensions.contains(fileExtension) || supportedVideoExtensions.contains(fileExtension)
            }
            .sorted { lhs, rhs in
                lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
            }

        guard candidateURLs.count == 1, let candidateURL = candidateURLs.first else {
            return nil
        }

        let fileExtension = candidateURL.pathExtension.lowercased()
        if supportedVideoExtensions.contains(fileExtension) {
            return .video(
                StickerVideoAsset(
                    sourceURL: candidateURL,
                    cacheKey: fileSignature(for: candidateURL),
                    mimeType: mimeType(forVideoExtension: fileExtension)
                )
            )
        }

        let frames = rasterFrames(from: candidateURL, defaultFrameDuration: defaultSequenceFrameDuration)
        return frames.isEmpty ? nil : .rasterFrames(frames)
    }

    private static func rasterFrames(from url: URL, defaultFrameDuration: TimeInterval) -> [StickerFrameAsset] {
        guard FileManager.default.fileExists(atPath: url.path),
              let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return []
        }

        let frameCount = max(CGImageSourceGetCount(imageSource), 0)
        guard frameCount > 0 else {
            return []
        }

        let baseCacheKey = fileSignature(for: url)
        var frames: [StickerFrameAsset] = []
        frames.reserveCapacity(frameCount)

        for index in 0..<frameCount {
            guard let cgImage = CGImageSourceCreateImageAtIndex(imageSource, index, nil),
                  let materializedImage = rasterizedCopy(of: cgImage) else {
                continue
            }

            let duration = frameDuration(
                from: imageSource,
                frameIndex: index,
                defaultFrameDuration: defaultFrameDuration
            )

            frames.append(
                StickerFrameAsset(
                    image: StickerImage(cgImage: materializedImage),
                    duration: duration,
                    cacheKey: "\(baseCacheKey)#\(index)",
                    sourceURL: url,
                    skipBackgroundRemoval: false
                )
            )
        }

        return frames
    }

    private static func frameDuration(
        from imageSource: CGImageSource,
        frameIndex: Int,
        defaultFrameDuration: TimeInterval
    ) -> TimeInterval {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, frameIndex, nil) as? [CFString: Any] else {
            return defaultFrameDuration
        }

        let gifProperties = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let pngProperties = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]

        let unclampedDelay =
            (gifProperties?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (pngProperties?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)

        let clampedDelay =
            (gifProperties?[kCGImagePropertyGIFDelayTime] as? Double)
            ?? (pngProperties?[kCGImagePropertyAPNGDelayTime] as? Double)

        let rawDuration = unclampedDelay ?? clampedDelay ?? defaultFrameDuration
        return max(1.0 / 30.0, rawDuration)
    }

    private static func fileSignature(for url: URL) -> String {
        let standardizedURL = url.standardizedFileURL
        let resourceValues = try? standardizedURL.resourceValues(forKeys: [
            .fileSizeKey,
            .contentModificationDateKey
        ])
        let fileSize = resourceValues?.fileSize ?? -1
        let modificationTimestamp = Int(resourceValues?.contentModificationDate?.timeIntervalSince1970 ?? 0)
        return "\(standardizedURL.path)|\(fileSize)|\(modificationTimestamp)"
    }

    private static func mimeType(forVideoExtension fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "webm":
            return "video/webm"
        case "mp4", "m4v":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        default:
            return "application/octet-stream"
        }
    }

    private static func rasterizedCopy(of image: CGImage) -> CGImage? {
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
}

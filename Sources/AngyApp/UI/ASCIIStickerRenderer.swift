import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import QuartzCore
import UniformTypeIdentifiers

struct RenderedASCIISticker: Sendable {
    let image: StickerImage
    let layoutSize: CGSize
    let sourceSize: CGSize
}

struct RenderedASCIIStickerFrame: Sendable {
    let sticker: RenderedASCIISticker
    let duration: TimeInterval
}

struct RenderedASCIIStickerSequence: Sendable {
    let frames: [RenderedASCIIStickerFrame]
    let layoutSize: CGSize
    let sourceSize: CGSize

    var firstFrame: RenderedASCIISticker? {
        frames.first?.sticker
    }
}

actor ASCIIStickerRenderer {
    static let shared = ASCIIStickerRenderer()

    private let maxDisplayDimension: CGFloat = 120
    private let alphaThreshold: UInt8 = 8
    private let backgroundLuminanceThreshold: UInt8 = 72
    private let backgroundColorTolerance: Int = 44
    private let pipelineVersion = 7
    private let fileManager = FileManager.default
    private let debugEnabled = ProcessInfo.processInfo.environment["ANGY_DEBUG"] == "1"
    private let verboseEnabled = ProcessInfo.processInfo.environment["ANGY_DEBUG_VERBOSE"] == "1"
    private var memoryCache: [String: RenderedASCIIStickerSequence] = [:]

    private var traceEnabled: Bool {
        debugEnabled && verboseEnabled
    }

    func renderSequence(from assetSource: StickerAssetSource?) async -> RenderedASCIIStickerSequence? {
        guard let assetSource else {
            return nil
        }

        let cacheDescriptor = pipelineCacheDescriptor(for: assetSource)

        if traceEnabled {
            print("[AngyStickerRenderer] renderSequence start key=\(assetSource.cacheKey)")
        }

        if let cached = memoryCache[cacheDescriptor] {
            if traceEnabled {
                print("[AngyStickerRenderer] memory-cache-hit key=\(assetSource.cacheKey)")
            }
            return cached
        }

        if let diskCached = loadSequenceFromDisk(cacheDescriptor: cacheDescriptor) {
            memoryCache[cacheDescriptor] = diskCached
            if traceEnabled {
                print("[AngyStickerRenderer] disk-cache-hit key=\(assetSource.cacheKey)")
            }
            return diskCached
        }

        let frameAssets: [StickerFrameAsset]
        switch assetSource {
        case .rasterFrames(let frames):
            frameAssets = frames
        case .video(let asset):
            frameAssets = await WebVideoStickerDecoder.shared.decodeFrames(from: asset)
        }

        guard !frameAssets.isEmpty else {
            if traceEnabled {
                print("[AngyStickerRenderer] no-frames key=\(assetSource.cacheKey)")
            }
            return nil
        }

        if frameAssets.allSatisfy(\.skipBackgroundRemoval) {
            let renderedFrames = frameAssets.compactMap(renderedDirectFrame(from:))
            guard !renderedFrames.isEmpty else {
                if traceEnabled {
                    print("[AngyStickerRenderer] direct-render-failed key=\(assetSource.cacheKey)")
                }
                return nil
            }

            let layoutSize = renderedFrames.reduce(.zero) { partialResult, frame in
                CGSize(
                    width: max(partialResult.width, frame.sticker.layoutSize.width),
                    height: max(partialResult.height, frame.sticker.layoutSize.height)
                )
            }

            let sourceSize = renderedFrames.first?.sticker.sourceSize ?? .zero
            let sequence = RenderedASCIIStickerSequence(
                frames: renderedFrames,
                layoutSize: layoutSize,
                sourceSize: sourceSize
            )

            memoryCache[cacheDescriptor] = sequence
            saveSequenceToDisk(sequence, cacheDescriptor: cacheDescriptor)
            return sequence
        }

        let preparedFrames = frameAssets.compactMap(preparedFrame(from:))
        guard !preparedFrames.isEmpty else {
            if traceEnabled {
                print("[AngyStickerRenderer] prepare-failed key=\(assetSource.cacheKey)")
            }
            return nil
        }

        let cropRect = sequenceCropRect(for: preparedFrames)
        let renderedFrames = preparedFrames.compactMap { renderedFrame(from: $0, cropRect: cropRect) }
        guard !renderedFrames.isEmpty else {
            if traceEnabled {
                print("[AngyStickerRenderer] render-failed key=\(assetSource.cacheKey)")
            }
            return nil
        }

        let layoutSize = renderedFrames.reduce(.zero) { partialResult, frame in
            CGSize(
                width: max(partialResult.width, frame.sticker.layoutSize.width),
                height: max(partialResult.height, frame.sticker.layoutSize.height)
            )
        }

        let sourceSize = renderedFrames.first?.sticker.sourceSize ?? .zero
        let sequence = RenderedASCIIStickerSequence(
            frames: renderedFrames,
            layoutSize: layoutSize,
            sourceSize: sourceSize
        )

        memoryCache[cacheDescriptor] = sequence
        saveSequenceToDisk(sequence, cacheDescriptor: cacheDescriptor)

        if traceEnabled {
            print("[AngyStickerRenderer] renderSequence finished key=\(assetSource.cacheKey) frames=\(sequence.frames.count) size=\(Int(sequence.layoutSize.width))x\(Int(sequence.layoutSize.height))")
        }

        return sequence
    }

    private func pipelineCacheDescriptor(for assetSource: StickerAssetSource) -> String {
        "\(assetSource.cacheKey)|render-v\(pipelineVersion)|max:\(Int(maxDisplayDimension))|alpha:\(alphaThreshold)|bg:\(backgroundLuminanceThreshold)"
    }

    private func preparedFrame(from asset: StickerFrameAsset) -> PreparedStickerFrame? {
        let cgImage = asset.image.cgImage
        guard let rgbaBytes = rgbaBytes(for: cgImage) else {
            return nil
        }

        let processedBytes: [UInt8]
        if asset.skipBackgroundRemoval {
            processedBytes = rgbaBytes
        } else {
            processedBytes = backgroundRemovedBytes(
                from: rgbaBytes,
                width: cgImage.width,
                height: cgImage.height
            )
        }

        let fullRect = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
        let contentRect = alphaContentRect(
            in: processedBytes,
            width: cgImage.width,
            height: cgImage.height
        ) ?? fullRect

        return PreparedStickerFrame(
            rgbaBytes: processedBytes,
            width: cgImage.width,
            height: cgImage.height,
            duration: max(1.0 / 30.0, asset.duration),
            contentRect: contentRect
        )
    }

    private func renderedFrame(from frame: PreparedStickerFrame, cropRect: CGRect) -> RenderedASCIIStickerFrame? {
        let sourceSize = CGSize(width: cropRect.width, height: cropRect.height)
        let layoutSize = scaledDisplaySize(for: sourceSize)

        guard let image = image(
            from: frame.rgbaBytes,
            width: frame.width,
            height: frame.height,
            cropRect: cropRect,
            targetSize: layoutSize
        ) else {
            return nil
        }

        let renderedSticker = RenderedASCIISticker(
            image: StickerImage(cgImage: image),
            layoutSize: layoutSize,
            sourceSize: sourceSize
        )

        return RenderedASCIIStickerFrame(
            sticker: renderedSticker,
            duration: frame.duration
        )
    }

    private func renderedDirectFrame(from asset: StickerFrameAsset) -> RenderedASCIIStickerFrame? {
        let sourceImage = asset.image.cgImage
        let sourceSize = CGSize(width: sourceImage.width, height: sourceImage.height)
        let layoutSize = scaledDisplaySize(for: sourceSize)

        guard let image = scaledImage(from: sourceImage, targetSize: layoutSize) else {
            return nil
        }

        let renderedSticker = RenderedASCIISticker(
            image: StickerImage(cgImage: image),
            layoutSize: layoutSize,
            sourceSize: sourceSize
        )

        return RenderedASCIIStickerFrame(
            sticker: renderedSticker,
            duration: max(1.0 / 30.0, asset.duration)
        )
    }

    private func sequenceCropRect(for frames: [PreparedStickerFrame]) -> CGRect {
        let unionRect = frames.reduce(CGRect.null) { partialResult, frame in
            partialResult.union(frame.contentRect)
        }

        guard !unionRect.isNull else {
            let first = frames[0]
            return CGRect(x: 0, y: 0, width: first.width, height: first.height)
        }

        return unionRect.integral
    }

    private func scaledDisplaySize(for sourceSize: CGSize) -> CGSize {
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return .zero
        }

        let scale = maxDisplayDimension / max(sourceSize.width, sourceSize.height)
        return CGSize(
            width: max(1, ceil(sourceSize.width * scale)),
            height: max(1, ceil(sourceSize.height * scale))
        )
    }

    private func alphaContentRect(in rgbaBytes: [UInt8], width: Int, height: Int) -> CGRect? {
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1

        for y in 0..<height {
            for x in 0..<width {
                let alpha = rgbaBytes[((y * width) + x) * 4 + 3]
                guard alpha > alphaThreshold else {
                    continue
                }

                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return nil
        }

        return CGRect(
            x: minX,
            y: minY,
            width: (maxX - minX) + 1,
            height: (maxY - minY) + 1
        )
    }

    private func backgroundRemovedBytes(from rgbaBytes: [UInt8], width: Int, height: Int) -> [UInt8] {
        guard width > 0, height > 0 else {
            return rgbaBytes
        }

        let originalOpaquePixelCount = opaquePixelCount(in: rgbaBytes)
        let backgroundColor = sampledBorderBackgroundColor(in: rgbaBytes, width: width, height: height)
        var bytes = rgbaBytes
        var visited = [Bool](repeating: false, count: width * height)
        var queue: [(x: Int, y: Int)] = []

        func enqueueIfBackground(_ x: Int, _ y: Int) {
            guard x >= 0, x < width, y >= 0, y < height else {
                return
            }

            let index = (y * width) + x
            guard !visited[index] else {
                return
            }

            let offset = index * 4
            let red = bytes[offset]
            let green = bytes[offset + 1]
            let blue = bytes[offset + 2]
            let alpha = bytes[offset + 3]
            let luminance = max(red, max(green, blue))

            guard alpha > alphaThreshold,
                  luminance <= backgroundLuminanceThreshold,
                  colorDistanceSquared(
                    red: red,
                    green: green,
                    blue: blue,
                    background: backgroundColor
                  ) <= backgroundColorTolerance * backgroundColorTolerance else {
                return
            }

            visited[index] = true
            queue.append((x: x, y: y))
        }

        for x in 0..<width {
            enqueueIfBackground(x, 0)
            enqueueIfBackground(x, height - 1)
        }

        for y in 0..<height {
            enqueueIfBackground(0, y)
            enqueueIfBackground(width - 1, y)
        }

        var queueIndex = 0
        while queueIndex < queue.count {
            let point = queue[queueIndex]
            queueIndex += 1

            let offset = ((point.y * width) + point.x) * 4
            bytes[offset] = 0
            bytes[offset + 1] = 0
            bytes[offset + 2] = 0
            bytes[offset + 3] = 0

            enqueueIfBackground(point.x - 1, point.y)
            enqueueIfBackground(point.x + 1, point.y)
            enqueueIfBackground(point.x, point.y - 1)
            enqueueIfBackground(point.x, point.y + 1)
        }

        let remainingOpaquePixels = opaquePixelCount(in: bytes)
        let minimumRemainingPixels = max(256, Int(Double(originalOpaquePixelCount) * 0.01))
        if traceEnabled {
            print(
                "[AngyStickerRenderer] bgremove original=\(originalOpaquePixelCount) remaining=\(remainingOpaquePixels) minimum=\(minimumRemainingPixels) bg=\(backgroundColor.red),\(backgroundColor.green),\(backgroundColor.blue)"
            )
        }
        guard remainingOpaquePixels >= minimumRemainingPixels else {
            return rgbaBytes
        }

        return bytes
    }

    private func image(
        from rgbaBytes: [UInt8],
        width: Int,
        height: Int,
        cropRect: CGRect,
        targetSize: CGSize
    ) -> CGImage? {
        let clampedX = max(0, min(width - 1, Int(cropRect.origin.x)))
        let clampedY = max(0, min(height - 1, Int(cropRect.origin.y)))
        let cropWidth = max(1, min(width - clampedX, Int(cropRect.width)))
        let cropHeight = max(1, min(height - clampedY, Int(cropRect.height)))
        let bytesPerRow = cropWidth * 4

        var croppedBytes = [UInt8](repeating: 0, count: bytesPerRow * cropHeight)

        for row in 0..<cropHeight {
            let sourceOffset = (((clampedY + row) * width) + clampedX) * 4
            let destinationOffset = row * bytesPerRow
            let sourceSlice = rgbaBytes[sourceOffset..<(sourceOffset + bytesPerRow)]
            croppedBytes[destinationOffset..<(destinationOffset + bytesPerRow)] = sourceSlice
        }

        guard let croppedImage = imageFromBitmapBytes(
            from: croppedBytes,
            width: cropWidth,
            height: cropHeight,
            bytesPerRow: bytesPerRow
        ) else {
            return nil
        }

        let targetWidth = max(1, Int(targetSize.width.rounded(.up)))
        let targetHeight = max(1, Int(targetSize.height.rounded(.up)))
        guard targetWidth != cropWidth || targetHeight != cropHeight else {
            return croppedImage
        }

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return croppedImage
        }

        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        context.draw(croppedImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    private func imageFromBitmapBytes(
        from rgbaBytes: [UInt8],
        width: Int,
        height: Int,
        bytesPerRow: Int
    ) -> CGImage? {
        var mutableBytes = rgbaBytes
        let image = mutableBytes.withUnsafeMutableBytes { rawBuffer -> CGImage? in
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
                return nil
            }

            return context.makeImage()
        }

        return image
    }

    private func scaledImage(from sourceImage: CGImage, targetSize: CGSize) -> CGImage? {
        let targetWidth = max(1, Int(targetSize.width.rounded(.up)))
        let targetHeight = max(1, Int(targetSize.height.rounded(.up)))

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: targetWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return nil
        }

        context.interpolationQuality = .high
        context.clear(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage()
    }

    private func rgbaBytes(for cgImage: CGImage) -> [UInt8]? {
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

        return rendered ? bytes : nil
    }

    private func loadSequenceFromDisk(cacheDescriptor: String) -> RenderedASCIIStickerSequence? {
        let directoryURL = cacheDirectory(for: cacheDescriptor)
        let manifestURL = directoryURL.appendingPathComponent("manifest.json", isDirectory: false)

        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(DiskRenderedSequenceManifest.self, from: data),
              manifest.version == pipelineVersion else {
            return nil
        }

        let layoutSize = manifest.layoutSize.cgSize
        let sourceSize = manifest.sourceSize.cgSize

        let frames = manifest.frames.compactMap { entry -> RenderedASCIIStickerFrame? in
            let frameURL = directoryURL.appendingPathComponent(entry.fileName, isDirectory: false)
            guard let imageSource = CGImageSourceCreateWithURL(frameURL as CFURL, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                return nil
            }

            return RenderedASCIIStickerFrame(
                sticker: RenderedASCIISticker(
                    image: StickerImage(cgImage: cgImage),
                    layoutSize: layoutSize,
                    sourceSize: sourceSize
                ),
                duration: max(1.0 / 30.0, entry.duration)
            )
        }

        guard frames.count == manifest.frames.count, !frames.isEmpty else {
            return nil
        }

        return RenderedASCIIStickerSequence(
            frames: frames,
            layoutSize: layoutSize,
            sourceSize: sourceSize
        )
    }

    private func saveSequenceToDisk(_ sequence: RenderedASCIIStickerSequence, cacheDescriptor: String) {
        let directoryURL = cacheDirectory(for: cacheDescriptor)

        do {
            if fileManager.fileExists(atPath: directoryURL.path) {
                try fileManager.removeItem(at: directoryURL)
            }

            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

            var manifestFrames: [DiskRenderedFrameManifest] = []
            manifestFrames.reserveCapacity(sequence.frames.count)

            for (index, frame) in sequence.frames.enumerated() {
                let fileName = String(format: "frame_%04d.png", index)
                let frameURL = directoryURL.appendingPathComponent(fileName, isDirectory: false)
                try writePNG(frame.sticker.image.cgImage, to: frameURL)
                manifestFrames.append(
                    DiskRenderedFrameManifest(
                        fileName: fileName,
                        duration: frame.duration
                    )
                )
            }

            let manifest = DiskRenderedSequenceManifest(
                version: pipelineVersion,
                layoutSize: DiskCGSize(sequence.layoutSize),
                sourceSize: DiskCGSize(sequence.sourceSize),
                frames: manifestFrames
            )

            let data = try JSONEncoder().encode(manifest)
            try data.write(to: directoryURL.appendingPathComponent("manifest.json", isDirectory: false), options: .atomic)
        } catch {
            if traceEnabled {
                print("[AngyStickerRenderer] disk-cache-write-failed error=\(error)")
            }
        }
    }

    private func cacheDirectory(for cacheDescriptor: String) -> URL {
        cacheRootDirectory().appendingPathComponent(cacheDirectoryName(for: cacheDescriptor), isDirectory: true)
    }

    private func cacheRootDirectory() -> URL {
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        return currentDirectory
            .appendingPathComponent(".angy-cache", isDirectory: true)
            .appendingPathComponent("rendered-stickers", isDirectory: true)
    }

    private func cacheDirectoryName(for cacheDescriptor: String) -> String {
        let digest = SHA256.hash(data: Data(cacheDescriptor.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw StickerDiskCacheError.destinationCreationFailed
        }

        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw StickerDiskCacheError.finalizeFailed
        }
    }

    private func opaquePixelCount(in rgbaBytes: [UInt8]) -> Int {
        var count = 0
        for index in stride(from: 3, to: rgbaBytes.count, by: 4) where rgbaBytes[index] > alphaThreshold {
            count += 1
        }
        return count
    }

    private func sampledBorderBackgroundColor(in rgbaBytes: [UInt8], width: Int, height: Int) -> RGBSample {
        var redTotal = 0
        var greenTotal = 0
        var blueTotal = 0
        var sampleCount = 0

        func sample(_ x: Int, _ y: Int) {
            let offset = ((y * width) + x) * 4
            let alpha = rgbaBytes[offset + 3]
            guard alpha > alphaThreshold else {
                return
            }

            redTotal += Int(rgbaBytes[offset])
            greenTotal += Int(rgbaBytes[offset + 1])
            blueTotal += Int(rgbaBytes[offset + 2])
            sampleCount += 1
        }

        for x in 0..<width {
            sample(x, 0)
            sample(x, height - 1)
        }

        for y in 1..<(max(1, height - 1)) {
            sample(0, y)
            sample(width - 1, y)
        }

        guard sampleCount > 0 else {
            return RGBSample(red: 0, green: 0, blue: 0)
        }

        return RGBSample(
            red: redTotal / sampleCount,
            green: greenTotal / sampleCount,
            blue: blueTotal / sampleCount
        )
    }

    private func colorDistanceSquared(
        red: UInt8,
        green: UInt8,
        blue: UInt8,
        background: RGBSample
    ) -> Int {
        let redDelta = Int(red) - background.red
        let greenDelta = Int(green) - background.green
        let blueDelta = Int(blue) - background.blue
        return (redDelta * redDelta) + (greenDelta * greenDelta) + (blueDelta * blueDelta)
    }
}

private struct PreparedStickerFrame {
    let rgbaBytes: [UInt8]
    let width: Int
    let height: Int
    let duration: TimeInterval
    let contentRect: CGRect
}

@MainActor
final class ASCIIStickerView: NSView {
    private let imageLayer = CALayer()
    private let animationKey = "sticker-frame-animation"
    private let explosionAnimationKey = "sticker-explosion"
    private var renderedSequence: RenderedASCIIStickerSequence?

    override var isFlipped: Bool {
        true
    }

    override var fittingSize: NSSize {
        renderedSequence?.layoutSize ?? .zero
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        imageLayer.backgroundColor = NSColor.clear.cgColor
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.actions = [
            "contents": NSNull(),
            "bounds": NSNull(),
            "position": NSNull()
        ]
        layer?.addSublayer(imageLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    func update(renderedSequence: RenderedASCIIStickerSequence?) {
        self.renderedSequence = renderedSequence
        isHidden = renderedSequence == nil
        invalidateIntrinsicContentSize()
        needsLayout = true
        updateLayerContents()
    }

    func playExplosionAnimation(duration: TimeInterval) {
        guard let layer else {
            return
        }

        layer.removeAnimation(forKey: explosionAnimationKey)

        let shake = CAKeyframeAnimation(keyPath: "transform.translation.x")
        shake.values = [0, -10, 10, -8, 8, -5, 5, 0]
        shake.keyTimes = [0, 0.12, 0.24, 0.38, 0.52, 0.68, 0.84, 1]

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1, 1.10, 1.22, 0.92, 0.30]
        scale.keyTimes = [0, 0.24, 0.42, 0.74, 1]

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0.85, 0.25, 0]
        fade.keyTimes = [0, 0.35, 0.58, 0.82, 1]

        let group = CAAnimationGroup()
        group.animations = [shake, scale, fade]
        group.duration = duration
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        layer.add(group, forKey: explosionAnimationKey)
    }

    func resetVisualEffects() {
        guard let layer else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: explosionAnimationKey)
        layer.opacity = 1
        layer.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    private func updateLayerContents() {
        imageLayer.removeAnimation(forKey: animationKey)

        guard let renderedSequence,
              let firstFrame = renderedSequence.firstFrame else {
            imageLayer.contents = nil
            return
        }

        updateContentsScale()
        imageLayer.contents = firstFrame.image.cgImage

        guard renderedSequence.frames.count > 1 else {
            return
        }

        imageLayer.add(contentsAnimation(for: renderedSequence), forKey: animationKey)
    }

    private func updateContentsScale() {
        imageLayer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }

    private func contentsAnimation(for sequence: RenderedASCIIStickerSequence) -> CAKeyframeAnimation {
        let totalDuration = max(sequence.frames.reduce(0) { $0 + $1.duration }, 1.0 / 30.0)
        var elapsed: TimeInterval = 0
        let keyTimes = sequence.frames.map { frame -> NSNumber in
            defer { elapsed += frame.duration }
            return NSNumber(value: elapsed / totalDuration)
        }

        let animation = CAKeyframeAnimation(keyPath: "contents")
        animation.values = sequence.frames.map(\.sticker.image.cgImage)
        animation.keyTimes = keyTimes
        animation.duration = totalDuration
        animation.repeatCount = .infinity
        animation.calculationMode = .discrete
        animation.isRemovedOnCompletion = false
        return animation
    }
}

private struct DiskRenderedSequenceManifest: Codable {
    let version: Int
    let layoutSize: DiskCGSize
    let sourceSize: DiskCGSize
    let frames: [DiskRenderedFrameManifest]
}

private struct DiskRenderedFrameManifest: Codable {
    let fileName: String
    let duration: TimeInterval
}

private struct DiskCGSize: Codable {
    let width: Double
    let height: Double

    init(_ size: CGSize) {
        width = size.width
        height = size.height
    }

    var cgSize: CGSize {
        CGSize(width: width, height: height)
    }
}

private enum StickerDiskCacheError: Error {
    case destinationCreationFailed
    case finalizeFailed
}

private struct RGBSample {
    let red: Int
    let green: Int
    let blue: Int
}

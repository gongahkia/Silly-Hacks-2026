import AppKit
import Foundation

@MainActor
final class CompanionOverlayView: NSView {
    private let placeholderSize = NSSize(width: 120, height: 120)
    private let stickerView = ASCIIStickerView(frame: .zero)
    private var currentStickerAssetKey: String?
    private var stickerLoadTask: Task<Void, Never>?
    private var currentContentSize: NSSize
    private let debugMonitor = DebugMonitor.shared
    var onSizeChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        currentContentSize = placeholderSize
        super.init(frame: frameRect)
        configureView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        stickerLoadTask?.cancel()
    }

    override var fittingSize: NSSize {
        currentContentSize
    }

    var overlaySize: CGSize {
        currentContentSize
    }

    override func layout() {
        super.layout()

        stickerView.frame = NSRect(
            x: 0,
            y: 0,
            width: currentContentSize.width,
            height: currentContentSize.height
        )
    }

    func update(stickerName: String) {
        let assetSource = CompanionPersona.assetSource(for: stickerName)
        let assetKey = assetSource?.cacheKey ?? "missing:\(stickerName)"

        if currentStickerAssetKey != assetKey {
            currentStickerAssetKey = assetKey
            stickerLoadTask?.cancel()
            stickerView.update(renderedSequence: nil)
            updateContentSize(placeholderSize)

            stickerLoadTask = Task { [weak self] in
                guard let self else { return }
                let renderedSequence = await ASCIIStickerRenderer.shared.renderSequence(from: assetSource)
                guard !Task.isCancelled else {
                    return
                }

                await MainActor.run {
                    guard self.currentStickerAssetKey == assetKey else {
                        return
                    }

                    self.stickerView.update(renderedSequence: renderedSequence)
                    self.debugMonitor.recordStickerAsset(
                        name: stickerName,
                        loaded: renderedSequence != nil,
                        size: renderedSequence?.sourceSize
                    )
                    self.updateContentSize(renderedSequence?.layoutSize ?? self.placeholderSize)
                }
            }
        }
    }

    private func configureView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        stickerView.isHidden = true
        addSubview(stickerView)
    }

    private func updateContentSize(_ size: CGSize) {
        let nextSize = NSSize(width: max(1, size.width), height: max(1, size.height))
        guard currentContentSize != nextSize else {
            return
        }

        currentContentSize = nextSize
        needsLayout = true
        invalidateIntrinsicContentSize()
        onSizeChange?()
    }
}

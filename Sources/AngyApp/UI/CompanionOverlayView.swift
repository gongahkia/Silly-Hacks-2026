import AppKit
import Foundation

@MainActor
final class CompanionOverlayView: NSView {
    private let placeholderStickerSize = NSSize(width: 120, height: 120)
    private let rageMeterHeight: CGFloat = 10
    private let verticalSpacing: CGFloat = 10
    private let explosionAnimationDuration: TimeInterval = 0.6
    private let stickerView = ASCIIStickerView(frame: .zero)
    private let tombstoneView = TombstoneView(frame: .zero)
    private let rageMeterView = RageMeterView(frame: .zero)
    private let flashLayer = CALayer()
    private var currentStickerAssetKey: String?
    private var stickerLoadTask: Task<Void, Never>?
    private var currentStickerSize: NSSize
    private var currentContentSize: NSSize
    private var currentEffectPhase: OverlayEffectPhase = .alive
    private var dragStartOrigin: CGPoint?
    private var dragStartCursorLocation: CGPoint?
    private let debugMonitor = DebugMonitor.shared
    var onDrag: ((CGPoint) -> Void)?
    var onSizeChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        currentStickerSize = placeholderStickerSize
        currentContentSize = Self.overlaySize(
            forStickerBody: placeholderStickerSize,
            rageMeterHeight: 10,
            verticalSpacing: 10
        )
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    var overlaySize: CGSize {
        currentContentSize
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func layout() {
        super.layout()

        let bodyHeight = max(1, currentContentSize.height - rageMeterHeight - verticalSpacing)
        let bodySize = currentEffectPhase == .tombstone ? tombstoneView.fittingSize : currentStickerSize
        let bodyFrame = NSRect(
            x: (currentContentSize.width - bodySize.width) / 2,
            y: rageMeterHeight + verticalSpacing,
            width: bodySize.width,
            height: bodyHeight
        )

        stickerView.frame = bodyFrame
        tombstoneView.frame = bodyFrame
        rageMeterView.frame = NSRect(x: 0, y: 0, width: currentContentSize.width, height: rageMeterHeight)
        flashLayer.frame = bounds
    }

    func update(presentation: OverlayPresentationState) {
        rageMeterView.update(score: presentation.angerScore)
        loadStickerIfNeeded(named: presentation.stickerName)
        applyEffectPhase(presentation.effectPhase)
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else {
            super.mouseDown(with: event)
            return
        }

        dragStartOrigin = window.frame.origin
        dragStartCursorLocation = window.convertPoint(toScreen: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartOrigin, let dragStartCursorLocation, let window else {
            super.mouseDragged(with: event)
            return
        }

        let currentCursorLocation = window.convertPoint(toScreen: event.locationInWindow)
        let draggedOrigin = CGPoint(
            x: dragStartOrigin.x + (currentCursorLocation.x - dragStartCursorLocation.x),
            y: dragStartOrigin.y + (currentCursorLocation.y - dragStartCursorLocation.y)
        )
        onDrag?(draggedOrigin)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDragged(with: event)
        dragStartOrigin = nil
        dragStartCursorLocation = nil
    }

    private func loadStickerIfNeeded(named stickerName: String) {
        let assetSource = CompanionPersona.assetSource(for: stickerName)
        let assetKey = assetSource?.cacheKey ?? "missing:\(stickerName)"

        guard currentStickerAssetKey != assetKey else {
            return
        }

        currentStickerAssetKey = assetKey
        stickerLoadTask?.cancel()
        stickerView.resetVisualEffects()
        stickerView.update(renderedSequence: nil)

        if currentEffectPhase != .tombstone {
            updateStickerBodySize(placeholderStickerSize)
        }

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
                self.currentStickerSize = renderedSequence.map { NSSize(width: $0.layoutSize.width, height: $0.layoutSize.height) }
                    ?? self.placeholderStickerSize
                self.debugMonitor.recordStickerAsset(
                    name: stickerName,
                    loaded: renderedSequence != nil,
                    size: renderedSequence?.sourceSize
                )

                if self.currentEffectPhase != .tombstone {
                    self.updateStickerBodySize(self.currentStickerSize)
                }
            }
        }
    }

    private func applyEffectPhase(_ nextPhase: OverlayEffectPhase) {
        let previousPhase = currentEffectPhase
        currentEffectPhase = nextPhase

        switch nextPhase {
        case .alive:
            stickerView.resetVisualEffects()
            stickerView.isHidden = stickerView.fittingSize == .zero
            tombstoneView.isHidden = true
            flashLayer.removeAnimation(forKey: "explosion-flash")
            updateStickerBodySize(currentStickerSize)
        case .exploding:
            tombstoneView.isHidden = true
            stickerView.isHidden = false
            updateStickerBodySize(currentStickerSize)

            if previousPhase != .exploding {
                stickerView.playExplosionAnimation(duration: explosionAnimationDuration)
                playExplosionFlash()
            }
        case .tombstone:
            stickerView.isHidden = true
            stickerView.resetVisualEffects()
            tombstoneView.isHidden = false
            flashLayer.removeAnimation(forKey: "explosion-flash")
            updateStickerBodySize(tombstoneView.fittingSize)
        }

        needsLayout = true
    }

    private func configureView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        stickerView.isHidden = true
        tombstoneView.isHidden = true

        addSubview(stickerView)
        addSubview(tombstoneView)
        addSubview(rageMeterView)

        flashLayer.backgroundColor = NSColor.white.withAlphaComponent(0.0).cgColor
        flashLayer.opacity = 0
        layer?.addSublayer(flashLayer)
    }

    private func updateStickerBodySize(_ stickerBodySize: CGSize) {
        let nextSize = Self.overlaySize(
            forStickerBody: stickerBodySize,
            rageMeterHeight: rageMeterHeight,
            verticalSpacing: verticalSpacing
        )
        guard currentContentSize != nextSize else {
            return
        }

        currentContentSize = nextSize
        needsLayout = true
        invalidateIntrinsicContentSize()
        onSizeChange?()
    }

    private func playExplosionFlash() {
        flashLayer.removeAnimation(forKey: "explosion-flash")

        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 0.65, 0]
        animation.keyTimes = [0, 0.18, 1]
        animation.duration = explosionAnimationDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flashLayer.add(animation, forKey: "explosion-flash")
    }

    private static func overlaySize(
        forStickerBody stickerBodySize: CGSize,
        rageMeterHeight: CGFloat,
        verticalSpacing: CGFloat
    ) -> NSSize {
        NSSize(
            width: max(120, stickerBodySize.width),
            height: max(120, stickerBodySize.height + rageMeterHeight + verticalSpacing)
        )
    }
}

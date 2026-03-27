import AngyCore
import AppKit
import Foundation

@MainActor
final class CompanionOverlayController {
    private let config: AppConfig
    private let panel: CompanionOverlayPanel
    private let contentView: CompanionOverlayView
    private var lastPresentedWindow: TrackedWindow?
    private var lastStickerName: String?
    private var cachedOverlaySize = NSSize(width: 120, height: 120)

    init(config: AppConfig) {
        self.config = config
        self.contentView = CompanionOverlayView(frame: .zero)
        self.panel = CompanionOverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 120))
        self.panel.contentView = contentView
        self.contentView.onSizeChange = { [weak self] in
            self?.cachedOverlaySize = self?.contentView.overlaySize ?? .zero
            self?.refreshPanelFrame()
        }
        self.cachedOverlaySize = contentView.overlaySize
    }

    func present(window: TrackedWindow, state _: CompanionState, stickerName: String, quip _: String?) {
        lastPresentedWindow = window
        if lastStickerName != stickerName {
            lastStickerName = stickerName
            contentView.update(stickerName: stickerName)
        }
        refreshPanelFrame()
    }

    func hide() {
        lastPresentedWindow = nil
        panel.orderOut(nil)
    }

    private func refreshPanelFrame() {
        guard let window = lastPresentedWindow else {
            return
        }

        let frame = overlayFrame(for: window.frame, overlaySize: cachedOverlaySize, preferredScreen: window.screenID)
        let shouldMove = !panel.isVisible || !panel.frame.integral.equalTo(frame.integral)

        if shouldMove {
            panel.setFrame(frame, display: false)
        }

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func overlayFrame(for windowFrame: CGRect, overlaySize: CGSize, preferredScreen: String?) -> CGRect {
        let centeredOverlapOriginY = windowFrame.maxY - (overlaySize.height * 0.5)
        let preferredOrigin = CGPoint(
            x: windowFrame.minX + config.overlayOffset.width,
            y: centeredOverlapOriginY
        )

        guard let screen = NSScreen.screens.first(where: { $0.localizedName == preferredScreen }) ??
                NSScreen.screens.first(where: { $0.frame.intersects(windowFrame) }) else {
            return CGRect(origin: preferredOrigin, size: overlaySize)
        }

        let minX = screen.frame.minX + config.overlayInsideFallbackPadding
        let maxX = screen.frame.maxX - overlaySize.width - config.overlayInsideFallbackPadding
        let visibleTopOriginY = screen.frame.maxY - overlaySize.height - config.overlayInsideFallbackPadding

        let clampedX = min(max(preferredOrigin.x, minX), maxX)
        let clampedY = min(preferredOrigin.y, visibleTopOriginY)

        let finalOrigin = CGPoint(x: clampedX, y: clampedY)

        return CGRect(origin: finalOrigin, size: overlaySize)
    }
}

private final class CompanionOverlayPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

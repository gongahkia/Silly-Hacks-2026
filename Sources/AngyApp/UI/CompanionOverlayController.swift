import AngyCore
import AppKit
import Foundation

@MainActor
final class CompanionOverlayController {
    private let config: AppConfig
    private let panel: CompanionOverlayPanel
    private let contentView: CompanionOverlayView

    init(config: AppConfig) {
        self.config = config
        self.contentView = CompanionOverlayView(frame: .zero)
        self.panel = CompanionOverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 120))
        self.panel.contentView = contentView
    }

    func present(window: TrackedWindow, state: CompanionState, stickerName: String, quip: String?) {
        contentView.update(state: state, stickerName: stickerName, quip: quip)

        let fittingSize = contentView.fittingSize
        let frame = overlayFrame(for: window.frame, overlaySize: fittingSize, preferredScreen: window.screenID)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func overlayFrame(for windowFrame: CGRect, overlaySize: CGSize, preferredScreen: String?) -> CGRect {
        let fallbackOrigin = CGPoint(
            x: windowFrame.minX + config.overlayInsideFallbackPadding,
            y: windowFrame.maxY - overlaySize.height - config.overlayInsideFallbackPadding
        )

        let preferredOrigin = CGPoint(
            x: windowFrame.minX + config.overlayOffset.width,
            y: windowFrame.maxY + config.overlayOffset.height
        )

        guard let screen = NSScreen.screens.first(where: { $0.localizedName == preferredScreen }) ??
                NSScreen.screens.first(where: { $0.frame.intersects(windowFrame) }) else {
            return CGRect(origin: preferredOrigin, size: overlaySize)
        }

        let fitsAboveWindow = preferredOrigin.y + overlaySize.height <= screen.frame.maxY - config.overlayInsideFallbackPadding
        let finalOrigin = fitsAboveWindow ? preferredOrigin : fallbackOrigin

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

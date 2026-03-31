import AngyCore
import AppKit
import Foundation

@MainActor
final class CompanionOverlayController {
    private let config: AppConfig
    private let panel: CompanionOverlayPanel
    private let contentView: CompanionOverlayView
    private let confettiOverlayController = ConfettiOverlayController()
    private var lastPresentedWindow: TrackedWindow?
    private var lastPresentation: OverlayPresentationState?
    private var cachedOverlaySize = NSSize(width: 120, height: 120)
    private var userDragOffset = CGSize.zero

    init(config: AppConfig) {
        self.config = config
        self.contentView = CompanionOverlayView(frame: .zero)
        self.panel = CompanionOverlayPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 120))
        self.panel.contentView = contentView
        self.contentView.onSizeChange = { [weak self] in
            self?.cachedOverlaySize = self?.contentView.overlaySize ?? .zero
            self?.refreshPanelFrame()
        }
        self.contentView.onDrag = { [weak self] draggedOrigin in
            self?.handleDrag(to: draggedOrigin)
        }
        self.cachedOverlaySize = contentView.overlaySize
    }

    func present(window: TrackedWindow, presentation: OverlayPresentationState) {
        lastPresentedWindow = window
        if lastPresentation != presentation {
            lastPresentation = presentation
            contentView.update(presentation: presentation)
        }
        confettiOverlayController.setVisible(presentation.effectPhase == .tombstone)
        refreshPanelFrame()
    }

    func hide() {
        lastPresentedWindow = nil
        panel.orderOut(nil)
        confettiOverlayController.setVisible(false)
    }

    private func refreshPanelFrame() {
        guard let window = lastPresentedWindow else {
            return
        }

        let frame = overlayFrame(
            for: window.frame,
            overlaySize: cachedOverlaySize,
            preferredScreen: window.screenID,
            userOffset: userDragOffset
        )
        let shouldMove = !panel.isVisible || !panel.frame.integral.equalTo(frame.integral)

        if shouldMove {
            panel.setFrame(frame, display: false)
        }

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func overlayFrame(
        for windowFrame: CGRect,
        overlaySize: CGSize,
        preferredScreen: String?,
        userOffset: CGSize
    ) -> CGRect {
        OverlayFrameCalculator.frame(
            windowFrame: windowFrame,
            overlaySize: overlaySize,
            baseOffset: config.overlayOffset,
            userOffset: userOffset,
            padding: config.overlayInsideFallbackPadding,
            screenFrame: resolvedScreenFrame(for: windowFrame, preferredScreen: preferredScreen)
        )
    }

    private func resolvedScreenFrame(for windowFrame: CGRect, preferredScreen: String?) -> CGRect? {
        if userDragOffset != .zero, panel.isVisible {
            let panelMidpoint = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
            if let draggedScreen = NSScreen.screens.first(where: { $0.frame.contains(panelMidpoint) }) ??
                NSScreen.screens.first(where: { $0.frame.intersects(panel.frame) }) {
                return draggedScreen.frame
            }
        }

        return NSScreen.screens.first(where: { $0.localizedName == preferredScreen })?.frame ??
            NSScreen.screens.first(where: { $0.frame.intersects(windowFrame) })?.frame
    }

    private func handleDrag(to draggedOrigin: CGPoint) {
        guard let window = lastPresentedWindow else {
            return
        }

        let defaultFrame = overlayFrame(
            for: window.frame,
            overlaySize: cachedOverlaySize,
            preferredScreen: window.screenID,
            userOffset: .zero
        )
        userDragOffset = CGSize(
            width: draggedOrigin.x - defaultFrame.origin.x,
            height: draggedOrigin.y - defaultFrame.origin.y
        )
        refreshPanelFrame()
    }
}

struct OverlayFrameCalculator {
    static func frame(
        windowFrame: CGRect,
        overlaySize: CGSize,
        baseOffset: CGSize,
        userOffset: CGSize,
        padding: CGFloat,
        screenFrame: CGRect?
    ) -> CGRect {
        let anchoredOrigin = CGPoint(
            x: windowFrame.minX + baseOffset.width,
            y: windowFrame.maxY - (overlaySize.height * 0.5)
        )
        let preferredOrigin = CGPoint(
            x: anchoredOrigin.x + userOffset.width,
            y: anchoredOrigin.y + userOffset.height
        )

        guard let screenFrame else {
            return CGRect(origin: preferredOrigin, size: overlaySize)
        }

        let minX = screenFrame.minX + padding
        let maxX = max(minX, screenFrame.maxX - overlaySize.width - padding)
        let minY = screenFrame.minY + padding
        let maxY = max(minY, screenFrame.maxY - overlaySize.height - padding)

        return CGRect(
            origin: CGPoint(
                x: min(max(preferredOrigin.x, minX), maxX),
                y: min(max(preferredOrigin.y, minY), maxY)
            ),
            size: overlaySize
        )
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
        hasShadow = true
        ignoresMouseEvents = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

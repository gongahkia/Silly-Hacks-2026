import AppKit
import Foundation

@MainActor
final class ConfettiOverlayController {
    private var panelsByScreenNumber: [NSNumber: ConfettiOverlayPanel] = [:]
    private var confettiImage: NSImage?
    private var lastResolvedImagePath: String?

    func setVisible(_ visible: Bool) {
        guard visible else {
            hideAllPanels()
            return
        }

        guard let image = loadConfettiImage() else {
            hideAllPanels()
            return
        }

        syncPanels(image: image)
    }

    private func syncPanels(image: NSImage) {
        let screens = NSScreen.screens
        let activeScreenNumbers = Set(screens.compactMap(Self.screenNumber(for:)))

        for (screenNumber, panel) in panelsByScreenNumber where !activeScreenNumbers.contains(screenNumber) {
            panel.orderOut(nil)
            panelsByScreenNumber.removeValue(forKey: screenNumber)
        }

        for screen in screens {
            guard let screenNumber = Self.screenNumber(for: screen) else {
                continue
            }

            let panel = panel(for: screenNumber, initialFrame: screen.frame)
            panel.setFrame(screen.frame, display: false)
            panel.setConfettiImage(image)

            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
        }
    }

    private func panel(for screenNumber: NSNumber, initialFrame: CGRect) -> ConfettiOverlayPanel {
        if let panel = panelsByScreenNumber[screenNumber] {
            return panel
        }

        let panel = ConfettiOverlayPanel(contentRect: initialFrame)
        panelsByScreenNumber[screenNumber] = panel
        return panel
    }

    private func hideAllPanels() {
        for panel in panelsByScreenNumber.values {
            panel.orderOut(nil)
        }
    }

    private func loadConfettiImage() -> NSImage? {
        guard let url = resolveConfettiURL() else {
            confettiImage = nil
            lastResolvedImagePath = nil
            return nil
        }

        if lastResolvedImagePath != url.path {
            confettiImage = NSImage(contentsOf: url)
            lastResolvedImagePath = url.path
        } else if confettiImage == nil {
            confettiImage = NSImage(contentsOf: url)
        }

        return confettiImage
    }

    private func resolveConfettiURL(
        processInfo: ProcessInfo = .processInfo,
        fileManager: FileManager = .default,
        bundle: Bundle = .module
    ) -> URL? {
        let environment = processInfo.environment

        if let overridePath = environment["ANGY_CONFETTI_GIF"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !overridePath.isEmpty {
            let overrideURL = URL(fileURLWithPath: overridePath, isDirectory: false)
            if fileManager.fileExists(atPath: overrideURL.path) {
                return overrideURL
            }
        }

        if let bundledURL = bundle.url(forResource: "confetti", withExtension: "gif", subdirectory: "Effects") ??
            bundle.url(forResource: "confetti", withExtension: "gif") {
            return bundledURL
        }

        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let rootURL = cwd.appendingPathComponent("confetti.gif", isDirectory: false)
        if fileManager.fileExists(atPath: rootURL.path) {
            return rootURL
        }

        return nil
    }

    private static func screenNumber(for screen: NSScreen) -> NSNumber? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }
}

private final class ConfettiOverlayPanel: NSPanel {
    private let confettiView: ConfettiOverlayView

    init(contentRect: NSRect) {
        confettiView = ConfettiOverlayView(frame: NSRect(origin: .zero, size: contentRect.size))
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
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        animationBehavior = .none
        contentView = confettiView
    }

    func setConfettiImage(_ image: NSImage) {
        confettiView.setImage(image)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class ConfettiOverlayView: NSView {
    private let imageView = NSImageView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.animates = true
        imageView.frame = bounds
        imageView.autoresizingMask = [.width, .height]
        addSubview(imageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setImage(_ image: NSImage) {
        if imageView.image !== image {
            imageView.image = image
        }
    }
}

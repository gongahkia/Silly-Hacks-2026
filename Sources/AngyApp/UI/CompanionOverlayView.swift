import AppKit
import Foundation

@MainActor
final class CompanionOverlayView: NSView {
    private let asciiLabel = NSTextField(labelWithString: "")
    private let stickerView = NSImageView(frame: .zero)
    private let quipContainer = NSView(frame: .zero)
    private let quipLabel = NSTextField(labelWithString: "")
    private var currentStickerName: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var fittingSize: NSSize {
        let asciiSize = asciiLabel.sizeThatFits(width: 160)
        let topRowWidth = asciiSize.width + (stickerView.isHidden ? 0 : 72 + 12)
        let topRowHeight = max(asciiSize.height, stickerView.isHidden ? 0 : 72)
        let quipSize = quipLabel.stringValue.isEmpty ? .zero : quipLabel.sizeThatFits(width: 220)
        let width = max(topRowWidth, quipSize.width + 24)
        let height = topRowHeight + (quipSize == .zero ? 0 : quipSize.height + 18)
        return NSSize(width: max(120, width), height: max(74, height))
    }

    override func layout() {
        super.layout()

        let width = bounds.width
        let stickerWidth: CGFloat = stickerView.isHidden ? 0 : 72
        let asciiWidth = max(120, width - stickerWidth - (stickerView.isHidden ? 0 : 12))
        let asciiSize = asciiLabel.sizeThatFits(width: asciiWidth)
        let topRowHeight = max(asciiSize.height, stickerView.isHidden ? 0 : 72)
        let quipSize = quipLabel.stringValue.isEmpty ? .zero : quipLabel.sizeThatFits(width: width - 24)
        let topRowY = quipSize == .zero ? 0 : quipSize.height + 18

        asciiLabel.frame = NSRect(
            x: 0,
            y: topRowY + (topRowHeight - asciiSize.height) / 2,
            width: asciiWidth,
            height: asciiSize.height
        )

        stickerView.frame = NSRect(
            x: asciiLabel.frame.maxX + (stickerView.isHidden ? 0 : 12),
            y: topRowY + (topRowHeight - 72) / 2,
            width: stickerWidth,
            height: stickerWidth
        )

        if quipSize == .zero {
            quipContainer.isHidden = true
        } else {
            quipContainer.isHidden = false
            quipContainer.frame = NSRect(x: 0, y: 0, width: quipSize.width + 24, height: quipSize.height + 10)
            quipLabel.frame = NSRect(x: 12, y: 5, width: quipSize.width, height: quipSize.height)
        }
    }

    func update(pose: String, stickerName: String, quip: String?) {
        asciiLabel.stringValue = pose
        if currentStickerName != stickerName {
            stickerView.image = CompanionPersona.image(for: stickerName)
            stickerView.isHidden = stickerView.image == nil
            currentStickerName = stickerName
        }
        quipLabel.stringValue = quip ?? ""
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    private func configureView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        asciiLabel.font = NSFont(name: "Menlo-Bold", size: 18) ?? .monospacedSystemFont(ofSize: 18, weight: .bold)
        asciiLabel.lineBreakMode = .byWordWrapping
        asciiLabel.maximumNumberOfLines = 0
        asciiLabel.alignment = .left
        asciiLabel.backgroundColor = .clear
        asciiLabel.textColor = NSColor.black.withAlphaComponent(0.92)
        asciiLabel.translatesAutoresizingMaskIntoConstraints = false
        asciiLabel.usesSingleLineMode = false
        addSubview(asciiLabel)

        stickerView.imageScaling = .scaleProportionallyUpOrDown
        stickerView.isHidden = true
        addSubview(stickerView)

        quipContainer.wantsLayer = true
        quipContainer.layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.9).cgColor
        quipContainer.layer?.cornerRadius = 12
        quipContainer.layer?.borderWidth = 1
        quipContainer.layer?.borderColor = NSColor.black.withAlphaComponent(0.14).cgColor
        addSubview(quipContainer)

        quipLabel.font = NSFont(name: "Menlo-Regular", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        quipLabel.textColor = NSColor.black.withAlphaComponent(0.9)
        quipLabel.lineBreakMode = .byWordWrapping
        quipLabel.maximumNumberOfLines = 2
        quipLabel.backgroundColor = .clear
        quipLabel.alignment = .left
        quipContainer.addSubview(quipLabel)
    }
}

private extension NSTextField {
    func sizeThatFits(width: CGFloat) -> CGSize {
        let bounds = attributedStringValue.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: ceil(bounds.width), height: ceil(bounds.height))
    }
}

import AngyCore
import AppKit
import Foundation

@MainActor
final class CompanionOverlayView: NSView {
    private let mascotBadge = NSView(frame: .zero)
    private let mascotLabel = NSTextField(labelWithString: "🐼")
    private let stickerView = NSImageView(frame: .zero)
    private let quipContainer = NSView(frame: .zero)
    private let quipLabel = NSTextField(labelWithString: "")

    private let badgeSize = CGSize(width: 54, height: 54)
    private let stickerSize = CGSize(width: 72, height: 72)
    private let horizontalGap: CGFloat = 10

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var fittingSize: NSSize {
        let topRowWidth = badgeSize.width + horizontalGap + stickerSize.width
        let topRowHeight = max(badgeSize.height, stickerSize.height)
        let quipSize = quipLabel.stringValue.isEmpty ? .zero : quipLabel.sizeThatFits(width: 220)
        let width = max(topRowWidth, quipSize.width + 24)
        let height = topRowHeight + (quipSize == .zero ? 0 : quipSize.height + 18)
        return NSSize(width: ceil(width), height: ceil(height))
    }

    override func layout() {
        super.layout()

        let width = bounds.width
        let topRowHeight = max(badgeSize.height, stickerSize.height)
        let quipSize = quipLabel.stringValue.isEmpty ? .zero : quipLabel.sizeThatFits(width: max(220, width))
        let topRowY = quipSize == .zero ? 0 : quipSize.height + 18

        mascotBadge.frame = NSRect(
            x: 0,
            y: topRowY + (topRowHeight - badgeSize.height) / 2,
            width: badgeSize.width,
            height: badgeSize.height
        )

        mascotLabel.frame = mascotBadge.bounds

        stickerView.frame = NSRect(
            x: mascotBadge.frame.maxX + horizontalGap,
            y: topRowY + (topRowHeight - stickerSize.height) / 2,
            width: stickerSize.width,
            height: stickerSize.height
        )

        if quipSize == .zero {
            quipContainer.isHidden = true
        } else {
            quipContainer.isHidden = false
            quipContainer.frame = NSRect(x: 0, y: 0, width: quipSize.width + 24, height: quipSize.height + 10)
            quipLabel.frame = NSRect(x: 12, y: 5, width: quipSize.width, height: quipSize.height)
        }
    }

    func update(state: CompanionState, stickerName: String, quip: String?) {
        mascotBadge.layer?.backgroundColor = CompanionPersona.color(for: state).withAlphaComponent(0.92).cgColor
        mascotBadge.layer?.borderColor = CompanionPersona.color(for: state).highlight(withLevel: 0.22)?.cgColor
        stickerView.image = CompanionPersona.image(for: stickerName)
        quipLabel.stringValue = quip ?? ""
        quipContainer.layer?.borderColor = CompanionPersona.color(for: state).withAlphaComponent(0.28).cgColor
        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    private func configureView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        mascotBadge.wantsLayer = true
        mascotBadge.layer?.cornerRadius = badgeSize.width / 2
        mascotBadge.layer?.borderWidth = 1
        mascotBadge.layer?.shadowColor = NSColor.black.withAlphaComponent(0.25).cgColor
        mascotBadge.layer?.shadowRadius = 12
        mascotBadge.layer?.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(mascotBadge)

        mascotLabel.font = NSFont.systemFont(ofSize: 28)
        mascotLabel.alignment = .center
        mascotLabel.backgroundColor = .clear
        mascotLabel.textColor = .white
        mascotBadge.addSubview(mascotLabel)

        stickerView.imageScaling = .scaleProportionallyUpOrDown
        stickerView.wantsLayer = true
        stickerView.layer?.shadowColor = NSColor.black.withAlphaComponent(0.22).cgColor
        stickerView.layer?.shadowRadius = 10
        stickerView.layer?.shadowOffset = CGSize(width: 0, height: -2)
        addSubview(stickerView)

        quipContainer.wantsLayer = true
        quipContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.82).cgColor
        quipContainer.layer?.cornerRadius = 12
        quipContainer.layer?.borderWidth = 1
        addSubview(quipContainer)

        quipLabel.font = NSFont(name: "Menlo-Regular", size: 12) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)
        quipLabel.textColor = NSColor(calibratedWhite: 0.96, alpha: 0.95)
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

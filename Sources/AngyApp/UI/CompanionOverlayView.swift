import AngyCore
import AppKit
import Foundation

@MainActor
final class CompanionOverlayView: NSView {
    private let asciiLabel = NSTextField(labelWithString: "")
    private let quipContainer = NSView(frame: .zero)
    private let quipLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var fittingSize: NSSize {
        let asciiSize = asciiLabel.sizeThatFits(width: 220)
        let quipSize = quipLabel.stringValue.isEmpty ? .zero : quipLabel.sizeThatFits(width: 220)

        let width = max(asciiSize.width, quipSize.width + 24)
        let height = asciiSize.height + (quipSize == .zero ? 0 : quipSize.height + 18)
        return NSSize(width: max(120, width), height: max(74, height))
    }

    override func layout() {
        super.layout()

        let width = bounds.width
        let asciiSize = asciiLabel.sizeThatFits(width: width)
        let quipSize = quipLabel.stringValue.isEmpty ? .zero : quipLabel.sizeThatFits(width: width - 24)

        asciiLabel.frame = NSRect(
            x: 0,
            y: quipSize == .zero ? 0 : quipSize.height + 18,
            width: width,
            height: asciiSize.height
        )

        if quipSize == .zero {
            quipContainer.isHidden = true
        } else {
            quipContainer.isHidden = false
            quipContainer.frame = NSRect(x: 0, y: 0, width: quipSize.width + 24, height: quipSize.height + 10)
            quipLabel.frame = NSRect(x: 12, y: 5, width: quipSize.width, height: quipSize.height)
        }
    }

    func update(state: CompanionState, pose: String, quip: String?) {
        asciiLabel.stringValue = pose
        asciiLabel.textColor = CompanionPersona.color(for: state)
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
        asciiLabel.textColor = .white
        asciiLabel.translatesAutoresizingMaskIntoConstraints = false
        asciiLabel.usesSingleLineMode = false
        addSubview(asciiLabel)

        quipContainer.wantsLayer = true
        quipContainer.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.78).cgColor
        quipContainer.layer?.cornerRadius = 12
        quipContainer.layer?.borderWidth = 1
        quipContainer.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.16).cgColor
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

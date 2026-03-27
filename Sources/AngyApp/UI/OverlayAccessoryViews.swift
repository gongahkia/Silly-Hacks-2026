import AppKit
import QuartzCore

@MainActor
final class RageMeterView: NSView {
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private var currentScore = 0.0
    private var currentBand: RageMeterBand = .calm

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        trackLayer.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.08).cgColor
        trackLayer.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.18).cgColor
        trackLayer.borderWidth = 1
        trackLayer.cornerRadius = 5

        fillLayer.cornerRadius = 5

        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
        update(score: 0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        trackLayer.frame = bounds
        let width = max(0, bounds.width * CGFloat(currentScore / 100))
        fillLayer.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)

        CATransaction.commit()
    }

    func update(score: Double) {
        currentScore = min(100, max(0, score))
        currentBand = RageMeterBand.band(for: currentScore)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.backgroundColor = color(for: currentBand).cgColor
        let width = max(0, bounds.width * CGFloat(currentScore / 100))
        fillLayer.frame = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        CATransaction.commit()

        updateCriticalAnimation()
    }

    private func updateCriticalAnimation() {
        fillLayer.removeAnimation(forKey: "critical-pulse")

        guard currentBand == .critical else {
            fillLayer.opacity = 1
            return
        }

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0.35
        animation.duration = 0.35
        animation.autoreverses = true
        animation.repeatCount = .infinity
        fillLayer.add(animation, forKey: "critical-pulse")
    }

    private func color(for band: RageMeterBand) -> NSColor {
        switch band {
        case .calm:
            return NSColor(calibratedRed: 0.20, green: 0.77, blue: 0.67, alpha: 0.95)
        case .curious:
            return NSColor(calibratedRed: 0.29, green: 0.60, blue: 0.98, alpha: 0.95)
        case .annoyed:
            return NSColor(calibratedRed: 0.94, green: 0.66, blue: 0.20, alpha: 0.95)
        case .furious:
            return NSColor(calibratedRed: 0.90, green: 0.26, blue: 0.22, alpha: 0.95)
        case .critical:
            return NSColor(calibratedRed: 1.0, green: 0.10, blue: 0.10, alpha: 0.98)
        }
    }
}

@MainActor
final class TombstoneView: NSView {
    override var fittingSize: NSSize {
        NSSize(width: 92, height: 118)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let stoneRect = bounds.insetBy(dx: 10, dy: 8)
        let headHeight = stoneRect.height * 0.24
        let bodyRect = CGRect(
            x: stoneRect.minX,
            y: stoneRect.minY,
            width: stoneRect.width,
            height: stoneRect.height - (headHeight * 0.45)
        )
        let headRect = CGRect(
            x: stoneRect.minX,
            y: stoneRect.maxY - headHeight,
            width: stoneRect.width,
            height: headHeight
        )

        let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 16, yRadius: 16)
        let headPath = NSBezierPath(ovalIn: headRect)
        bodyPath.append(headPath)

        NSColor(calibratedWhite: 0.65, alpha: 0.96).setFill()
        bodyPath.fill()

        NSColor(calibratedWhite: 0.18, alpha: 0.18).setStroke()
        bodyPath.lineWidth = 2
        bodyPath.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: "Menlo-Bold", size: 18) ?? NSFont.monospacedSystemFont(ofSize: 18, weight: .bold),
            .foregroundColor: NSColor(calibratedWhite: 0.20, alpha: 0.92)
        ]
        let rip = NSAttributedString(string: "RIP", attributes: attributes)
        let textSize = rip.size()
        let textOrigin = CGPoint(
            x: bounds.midX - (textSize.width / 2),
            y: bounds.midY - (textSize.height / 2) - 6
        )
        rip.draw(at: textOrigin)
    }
}

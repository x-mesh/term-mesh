import AppKit
import QuartzCore
import Bonsplit

/// Card geometry for a terminal surface hosted in the window portal.
///
/// The surface fills a bonsplit card below its tab bar, inset by the card's
/// border on the left, right and bottom. The portal host is not flipped, so
/// the tab bar sits above the surface at larger y.
enum CardRingGeometry {
    /// Half the gap, so the glow never reaches the neighbouring card.
    static func glowPadding(gap: CGFloat) -> CGFloat { max(0, gap / 2) }

    static func cardFrame(forSurfaceFrame surface: NSRect) -> NSRect {
        let border = BonsplitCardMetrics.borderWidth
        return NSRect(
            x: surface.minX - border,
            y: surface.minY - border,
            width: surface.width + border * 2,
            height: surface.height + border + BonsplitCardMetrics.tabBarHeight
        )
    }

    static func ringViewFrame(forSurfaceFrame surface: NSRect, gap: CGFloat) -> NSRect {
        let pad = glowPadding(gap: gap)
        return cardFrame(forSurfaceFrame: surface).insetBy(dx: -pad, dy: -pad)
    }

    /// Stroke positions for a segment whose head travels one full loop along a
    /// path that repeats the card outline twice. Drawing the loop twice keeps
    /// the segment continuous when it crosses the outline's starting corner.
    static func strokeRange(headProgress: CGFloat, length: CGFloat) -> (start: CGFloat, end: CGFloat) {
        let head = headProgress + length
        return (start: (head - length) / 2, end: head / 2)
    }
}

/// The unread-notification ring drawn around a whole pane card.
///
/// It lives in the terminal portal host beside its surface rather than inside
/// it, because the surface clips to its own bounds and the ring has to cover
/// the tab bar above it and glow into the gap around the card.
final class CardRingView: NSView {
    private struct LapLayerSpec {
        let length: CGFloat
        let lineWidth: CGFloat
        let blurRadius: CGFloat
        let peakOpacity: Float
        let color: NSColor
    }

    private enum Style {
        static let faintColor = NSColor(srgbRed: 0x3B / 255, green: 0x82 / 255, blue: 0xF6 / 255, alpha: 0.38)
        static let faintLineWidth: CGFloat = 1.5
        static let glowColor = NSColor(srgbRed: 0x60 / 255, green: 0xA5 / 255, blue: 0xFA / 255, alpha: 1)
        static let headColor = NSColor(srgbRed: 0xD6 / 255, green: 0xE8 / 255, blue: 0xFF / 255, alpha: 1)
        static let lapDuration: CFTimeInterval = 5.0
        static let lapTiming = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.55, 1)
        static let fadeInEnd: NSNumber = 0.18
        static let fadeOutStart: NSNumber = 0.75
        static let lapAnimationKey = "term-mesh.card-ring.lap"

        // Longest and faintest first so the bright head draws on top.
        static let lapLayers: [LapLayerSpec] = [
            LapLayerSpec(length: 0.80, lineWidth: 14, blurRadius: 11, peakOpacity: 0.058, color: glowColor),
            LapLayerSpec(length: 0.57, lineWidth: 11.2, blurRadius: 8.6, peakOpacity: 0.099, color: glowColor),
            LapLayerSpec(length: 0.36, lineWidth: 8.2, blurRadius: 6.3, peakOpacity: 0.139, color: glowColor),
            LapLayerSpec(length: 0.17, lineWidth: 5.2, blurRadius: 4, peakOpacity: 0.18, color: glowColor),
            LapLayerSpec(length: 0.04, lineWidth: 1.6, blurRadius: 1.6, peakOpacity: 0.22, color: headColor),
        ]
    }

    /// The space left around the card outline for the glow.
    var glowPadding: CGFloat = CardRingGeometry.glowPadding(gap: BonsplitCardMetrics.gap) {
        didSet { if glowPadding != oldValue { updatePaths() } }
    }

    private let faintLayer = CAShapeLayer()
    private var lapLayers: [(layer: CAShapeLayer, spec: LapLayerSpec)] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        // The view already extends half the gap past the card; the blurred
        // glow is wider than that, so clip it here rather than let it draw
        // over the neighbouring card.
        layer?.masksToBounds = true

        faintLayer.fillColor = nil
        faintLayer.strokeColor = Style.faintColor.cgColor
        faintLayer.lineWidth = Style.faintLineWidth
        faintLayer.opacity = 0
        layer?.addSublayer(faintLayer)

        for spec in Style.lapLayers {
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.strokeColor = spec.color.cgColor
            shape.lineWidth = spec.lineWidth
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.opacity = 0
            shape.strokeStart = 0
            shape.strokeEnd = 0
            if spec.blurRadius > 0, let blur = CIFilter(name: "CIGaussianBlur") {
                blur.setValue(spec.blurRadius, forKey: kCIInputRadiusKey)
                shape.filters = [blur]
            }
            layer?.addSublayer(shape)
            lapLayers.append((shape, spec))
        }
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        updatePaths()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updatePaths()
    }

    func apply(ring: NotificationRingState) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch ring {
        case .hidden:
            isHidden = true
            faintLayer.opacity = 0
            for entry in lapLayers { entry.layer.removeAnimation(forKey: Style.lapAnimationKey) }
        case .faint:
            isHidden = false
            faintLayer.opacity = 1
        }
        CATransaction.commit()
    }

    func playLap() {
        for entry in lapLayers {
            let range0 = CardRingGeometry.strokeRange(headProgress: 0, length: entry.spec.length)
            let range1 = CardRingGeometry.strokeRange(headProgress: 1, length: entry.spec.length)

            let start = CABasicAnimation(keyPath: "strokeStart")
            start.fromValue = range0.start
            start.toValue = range1.start
            let end = CABasicAnimation(keyPath: "strokeEnd")
            end.fromValue = range0.end
            end.toValue = range1.end
            for travel in [start, end] { travel.timingFunction = Style.lapTiming }

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, entry.spec.peakOpacity, entry.spec.peakOpacity, 0]
            fade.keyTimes = [0, Style.fadeInEnd, Style.fadeOutStart, 1]

            let group = CAAnimationGroup()
            group.animations = [start, end, fade]
            group.duration = Style.lapDuration
            entry.layer.removeAnimation(forKey: Style.lapAnimationKey)
            entry.layer.add(group, forKey: Style.lapAnimationKey)
        }
    }

    private func updatePaths() {
        let outline = bounds.insetBy(
            dx: glowPadding + Style.faintLineWidth / 2,
            dy: glowPadding + Style.faintLineWidth / 2
        )
        guard outline.width > 0, outline.height > 0 else { return }
        let radius = BonsplitCardMetrics.cornerRadius
        let loop = CGPath(roundedRect: outline, cornerWidth: radius, cornerHeight: radius, transform: nil)
        let twice = CGMutablePath()
        twice.addPath(loop)
        twice.addPath(loop)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        faintLayer.frame = bounds
        faintLayer.path = loop
        for entry in lapLayers {
            entry.layer.frame = bounds
            entry.layer.path = twice
        }
        CATransaction.commit()
    }
}

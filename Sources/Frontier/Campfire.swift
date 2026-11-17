import AppKit
import AVFoundation
import QuartzCore

/// The campfire: real footage of a log fire filmed against black, screen-blended into a painted night
/// scene with firelight on the ground around it.
///
/// The clip is a small hardware-decoded H.264 loop, so the fire costs this process almost nothing and
/// no in-process GPU context is needed. As the timer runs down, a soft mask lowers the flames and the
/// light around them fades, until only the coals glow.
final class CampfireView: NSView {
    /// Height of the fire's base as a fraction of the scene.
    static let baseY: CGFloat = 0.36
    /// Where the bottom of the log pile sits within the clip's frame, from the bottom edge.
    private static let clipBase: CGFloat = 0.07
    private static let clipAspect: CGFloat = 600.0 / 720.0

    private let scenery = CALayer()
    private let glow = CALayer()
    private let ground = CALayer()
    private let halo = CALayer()
    private let coals = CALayer()
    private let fire = AVPlayerLayer()
    private let fireMask = CAGradientLayer()
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private let phaseLabel = NSTextField(labelWithString: "")
    private let clockLabel = NSTextField(labelWithString: "")
    private var paintedSize = CGSize.zero
    private var level: CGFloat = 1
    private var paused = false

    /// Stops playback and all animation (used while the desktop is completely covered).
    var isPaused: Bool {
        get { paused }
        set {
            guard newValue != paused, let root = layer else { return }
            paused = newValue
            if newValue {
                player?.pause()
                root.timeOffset = root.convertTime(CACurrentMediaTime(), from: nil)
                root.speed = 0
            } else {
                let at = root.timeOffset
                root.speed = 1; root.timeOffset = 0; root.beginTime = 0
                root.beginTime = root.convertTime(CACurrentMediaTime(), from: nil) - at
                player?.play()
            }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        guard let root = layer else { return }
        root.backgroundColor = Theme.NS.void.cgColor
        root.masksToBounds = true
        scenery.contentsGravity = .resize
        ground.contents = Self.radial(NSColor(hex: 0xFF7A1E))
        halo.contents = Self.radial(NSColor(hex: 0xFF8A2A))
        coals.contents = Self.radial(NSColor(hex: 0xFF4A12))
        glow.addSublayer(ground)
        glow.addSublayer(halo)

        fire.videoGravity = .resizeAspect
        // Screen blend: the clip's black background adds nothing, so only the fire itself lands on the scene.
        fire.compositingFilter = "screenBlendMode"
        fireMask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        fireMask.startPoint = CGPoint(x: 0.5, y: 0)
        fireMask.endPoint = CGPoint(x: 0.5, y: 1)
        fire.mask = fireMask
        startPlayback()

        for l in [scenery, glow, coals, fire] { root.addSublayer(l) }
        glow.add(Self.flicker(low: 0.80, high: 1.0, seed: 11), forKey: "flicker")
        coals.add(Self.flicker(low: 0.72, high: 1.0, seed: 29), forKey: "flicker")
        for label in [phaseLabel, clockLabel] {
            label.alignment = .center
            label.drawsBackground = false
            label.isBezeled = false
            label.isEditable = false
            addSubview(label)
        }
        layoutPieces()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func startPlayback() {
        let url = Res.url("Video/campfire.mp4")
        guard FileManager.default.fileExists(atPath: url.path) else {
            NSLog("Frontier: campfire.mp4 is missing; showing the coals only")
            return
        }
        let queue = AVQueuePlayer()
        queue.isMuted = true
        queue.preventsDisplaySleepDuringVideoPlayback = false    // a desktop ornament must never keep the Mac awake
        queue.allowsExternalPlayback = false
        queue.automaticallyWaitsToMinimizeStalling = false
        looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        fire.player = queue
        player = queue
        queue.play()
    }

    override func layout() {
        super.layout()
        layoutPieces()
    }

    private func layoutPieces() {
        let b = bounds
        guard b.width > 8, b.height > 8 else { return }
        let unit = min(b.width, b.height)
        let base = CGPoint(x: b.midX, y: b.height * Self.baseY)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scenery.frame = b
        glow.frame = b
        if paintedSize != b.size {
            paintedSize = b.size
            // One pixel per point is plenty for a night scene, and a quarter of the memory of Retina.
            scenery.contents = Scenery.campSurface(size: b.size)
        }
        ground.frame = CGRect(x: base.x - unit * 0.90, y: base.y - unit * 0.22, width: unit * 1.8, height: unit * 0.42)
        halo.frame = CGRect(x: base.x - unit * 0.75, y: base.y - unit * 0.55, width: unit * 1.5, height: unit * 1.5)
        coals.frame = CGRect(x: base.x - unit * 0.16, y: base.y - unit * 0.035, width: unit * 0.32, height: unit * 0.11)
        let fh = unit * 0.66, fw = fh * Self.clipAspect
        fire.frame = CGRect(x: base.x - fw / 2, y: base.y - fh * Self.clipBase, width: fw, height: fh)
        fireMask.frame = fire.bounds
        CATransaction.commit()
        phaseLabel.frame = NSRect(x: 0, y: b.height * 0.255, width: b.width, height: 24)
        clockLabel.frame = NSRect(x: 0, y: b.height * 0.158, width: b.width, height: 84)
        apply(animated: false)
    }

    func set(level: Double, animated: Bool = true) {
        let l = CGFloat(min(1, max(0, level)))
        guard abs(l - self.level) > 0.0015 || !animated else { return }
        self.level = l
        apply(animated: animated)
    }

    /// A dying fire: the flames are masked lower and lower, and everything they lit grows dim.
    private func apply(animated: Bool) {
        let l = level
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 1.5 : 0)
        if !animated { CATransaction.setDisableActions(true) }
        // The mask is solid up to `cut` and feathers out above it. At full burn it clears the frame.
        // The feather is deliberately long (half the frame) so the flames thin out upward instead of
        // ending on a visible line.
        let cut = 0.34 + 1.20 * l
        fireMask.locations = [0, NSNumber(value: Double(max(0.02, cut - 0.55))), NSNumber(value: Double(cut))]
        fire.opacity = l < 0.012 ? 0.10 : Float(0.40 + 0.60 * pow(l, 0.6))
        ground.opacity = Float(0.08 + 0.72 * pow(l, 0.75))
        halo.opacity = Float(0.03 + 0.34 * pow(l, 0.75))
        coals.opacity = Float(0.30 + 0.45 * pow(l, 0.4))
        CATransaction.commit()
    }

    func set(phase: String, clock: String) {
        let p = Self.text(phase.uppercased(), font: Theme.nsDisplay(15), color: Theme.NS.boneDim, kern: 3.2)
        let c = Self.text(clock, font: Theme.nsDisplay(64, weight: .heavy), color: Theme.NS.bone, kern: 2)
        if phaseLabel.attributedStringValue != p { phaseLabel.attributedStringValue = p }
        if clockLabel.attributedStringValue != c { clockLabel.attributedStringValue = c }
    }

    func tearDown() {
        player?.pause()
        looper?.disableLooping()
        fire.player = nil
        looper = nil; player = nil
        glow.removeAllAnimations()
        coals.removeAllAnimations()
        removeFromSuperview()
    }

    // MARK: Pieces

    private static func text(_ s: String, font: NSFont, color: NSColor, kern: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .kern: kern, .paragraphStyle: style])
    }

    /// Irregular brightness wobble, pre-baked as stepped keyframes (~12 per second) so the compositor
    /// only has to redraw the light when it actually changes.
    private static func flicker(low: Float, high: Float, seed: UInt64) -> CAAnimation {
        var rng = SeededRNG(seed: seed)
        var v = (low + high) / 2
        let values: [Float] = (0..<48).map { _ in
            v = min(high, max(low, v + Float.random(in: -0.07...0.07, using: &rng)))
            return v
        }
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = values
        a.duration = 4.0
        a.calculationMode = .discrete
        a.repeatCount = .infinity
        return a
    }

    private static func radial(_ color: NSColor) -> CGImage? {
        Paint.image(size: CGSize(width: 128, height: 128)) {
            let c = NSPoint(x: 64, y: 64)
            NSGradient(colorsAndLocations: (color.withAlphaComponent(1), 0), (color.withAlphaComponent(0.42), 0.25),
                       (color.withAlphaComponent(0.12), 0.6), (color.withAlphaComponent(0), 1))!
                .draw(fromCenter: c, radius: 0, toCenter: c, radius: 64, options: [])
        }.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}

/// Hand-painted (well, code-painted) scenery shared by the campfire and the honor visions.
enum Scenery {
    /// The camp at night: sky, ridges, treeline and bare ground, with a vignette baked in.
    /// The fire itself, logs included, is real footage laid over this.
    static func campSurface(size: CGSize) -> IOSurface? {
        Paint.surface(size: size, scale: 1) {
            let w = size.width, h = size.height
            let horizon = h * (CampfireView.baseY + 0.04)
            NSGradient(colorsAndLocations: (NSColor(hex: 0x120E0C), 0), (NSColor(hex: 0x0C0B10), 0.35),
                       (NSColor(hex: 0x050609), 1))!
                .draw(in: NSRect(x: 0, y: horizon, width: w, height: h - horizon), angle: 90)
            var rng = SeededRNG(seed: 0xCA3F)
            for _ in 0..<Int(w * h / 5200) {
                let x = CGFloat.random(in: 0...w, using: &rng)
                let y = CGFloat.random(in: horizon + h * 0.08...h, using: &rng)
                let r = CGFloat.random(in: 0.4...1.3, using: &rng)
                let depth = (y - horizon) / (h - horizon)
                NSColor(hex: 0xEDE4D2, alpha: CGFloat.random(in: 0.12...0.8, using: &rng) * depth).setFill()
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: r * 2, height: r * 2)).fill()
            }
            for (i, color) in [NSColor(hex: 0x0D0C10), NSColor(hex: 0x09080A)].enumerated() {
                let path = NSBezierPath()
                path.move(to: NSPoint(x: 0, y: 0))
                let amp = h * (0.07 - CGFloat(i) * 0.025), baseY = horizon + h * (0.05 - CGFloat(i) * 0.04)
                let p1 = CGFloat.random(in: 0...6, using: &rng), p2 = CGFloat.random(in: 0...6, using: &rng)
                var x: CGFloat = 0
                while x <= w + 8 {
                    let u = x / w
                    path.line(to: NSPoint(x: x, y: baseY + amp * (0.55 * sin(u * 5.1 + p1) + 0.3 * sin(u * 12.7 + p2) + 0.15 * sin(u * 31 + p1 * 2))))
                    x += 8
                }
                path.line(to: NSPoint(x: w, y: 0))
                path.close()
                color.setFill()
                path.fill()
            }
            // Pines along the horizon, denser at the edges so the fire sits in a clearing.
            NSColor(hex: 0x060506).setFill()
            var x: CGFloat = -20
            while x < w + 20 {
                let edge = abs(x / w - 0.5) * 2
                if CGFloat.random(in: 0...1, using: &rng) < 0.25 + 0.75 * pow(edge, 1.5) {
                    pine(at: NSPoint(x: x, y: horizon - h * 0.012),
                         height: h * CGFloat.random(in: 0.06...0.13, using: &rng) * (0.55 + 0.9 * edge), rng: &rng)
                }
                x += CGFloat.random(in: 14...38, using: &rng)
            }
            NSGradient(colorsAndLocations: (NSColor(hex: 0x030303), 0), (NSColor(hex: 0x0A0806), 1))!
                .draw(in: NSRect(x: 0, y: 0, width: w, height: horizon), angle: 90)
            NSGradient(colorsAndLocations: (NSColor(white: 0, alpha: 0), 0), (NSColor(white: 0, alpha: 0), 0.55),
                       (NSColor(white: 0, alpha: 0.75), 1))!
                .draw(in: NSRect(origin: .zero, size: size), relativeCenterPosition: .zero)
        }
    }

    static func pine(at p: NSPoint, height: CGFloat, rng: inout SeededRNG) {
        let tiers = 5
        let path = NSBezierPath()
        let width = height * CGFloat.random(in: 0.30...0.42, using: &rng)
        for t in 0..<tiers {
            let f = CGFloat(t) / CGFloat(tiers)
            let y0 = p.y + height * f * 0.82
            let tw = width * (1 - f * 0.78)
            path.move(to: NSPoint(x: p.x - tw / 2, y: y0))
            path.line(to: NSPoint(x: p.x, y: y0 + height * 0.34))
            path.line(to: NSPoint(x: p.x + tw / 2, y: y0))
            path.close()
        }
        path.appendRect(NSRect(x: p.x - width * 0.05, y: p.y - height * 0.05, width: width * 0.1, height: height * 0.1))
        path.fill()
    }
}

/// Deterministic RNG so the painted scenery is identical every launch.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

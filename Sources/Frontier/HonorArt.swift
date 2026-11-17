import AppKit
import FrontierCore

/// Paints the two visions: the stag at dawn (high honor) and the wolf under the moon (low honor).
/// Rendered once to a bitmap, so showing it costs nothing afterwards.
enum HonorArt {
    static func render(_ mood: HonorMood, size: CGSize, scale: CGFloat = 2) -> NSImage {
        guard mood != .neutral, size.width > 10, size.height > 10 else { return NSImage(size: size) }
        return Paint.image(size: size, scale: scale) {
            if mood == .stag { stag(size) } else { wolf(size) }
            vignette(size, strength: mood == .stag ? 0.5 : 0.7)
        }
    }

    // MARK: Stag — dawn

    /// Same picture, painted into a surface a layer can display without copying.
    static func surface(_ mood: HonorMood, size: CGSize, scale: CGFloat) -> IOSurface? {
        guard mood != .neutral, size.width > 10, size.height > 10 else { return nil }
        return Paint.surface(size: size, scale: scale) {
            if mood == .stag { stag(size) } else { wolf(size) }
            vignette(size, strength: mood == .stag ? 0.5 : 0.7)
        }
    }

    private static func stag(_ s: CGSize) {
        let w = s.width, h = s.height
        var rng = SeededRNG(seed: 0x57A6)
        NSGradient(colorsAndLocations: (NSColor(hex: 0xF3C777), 0), (NSColor(hex: 0xE39B52), 0.18),
                   (NSColor(hex: 0xA9603F), 0.42), (NSColor(hex: 0x4A3340), 0.74), (NSColor(hex: 0x1D1A2A), 1))!
            .draw(in: NSRect(x: 0, y: h * 0.26, width: w, height: h * 0.74), angle: 90)
        // Sun, low on the horizon, with its bloom.
        let sun = NSPoint(x: w * 0.66, y: h * 0.40)
        glow(at: sun, radius: h * 0.62, color: NSColor(hex: 0xFFE2A0), alpha: 0.55)
        glow(at: sun, radius: h * 0.20, color: NSColor(hex: 0xFFF3CF), alpha: 0.9)
        NSColor(hex: 0xFFF6DC).setFill()
        NSBezierPath(ovalIn: NSRect(x: sun.x - h * 0.045, y: sun.y - h * 0.045, width: h * 0.09, height: h * 0.09)).fill()
        // Hazy ridges fading forward into shadow.
        let ridges: [(UInt32, CGFloat, CGFloat)] = [(0xC98A55, 0.40, 0.10), (0x9A6040, 0.35, 0.085), (0x65402F, 0.30, 0.07), (0x38241D, 0.25, 0.05)]
        for (i, r) in ridges.enumerated() {
            ridge(w: w, h: h, base: h * r.1, amp: h * r.2, color: NSColor(hex: r.0), rng: &rng,
                  pines: i >= 2 ? 0.5 : 0, pineHeight: h * (0.035 + CGFloat(i) * 0.012), pineColor: NSColor(hex: r.0))
        }
        // The near rise the stag stands on.
        let ground = NSColor(hex: 0x120D0A)
        let rise = hill(w: w, h: h, peakX: 0.30, peakY: 0.235, color: ground)
        ground.setFill()
        var x = w * 0.62
        while x < w + 30 {
            Scenery.pine(at: NSPoint(x: x, y: rise(x) - h * 0.01), height: h * CGFloat.random(in: 0.10...0.24, using: &rng), rng: &rng)
            x += CGFloat.random(in: 26...70, using: &rng)
        }
        let stagH = h * 0.36
        let px = w * 0.30
        draw("stag", color: ground, in: NSRect(x: px - stagH / 2, y: rise(px) - stagH * 0.045, width: stagH, height: stagH))
    }

    // MARK: Wolf — night

    private static func wolf(_ s: CGSize) {
        let w = s.width, h = s.height
        var rng = SeededRNG(seed: 0x301F)
        NSGradient(colorsAndLocations: (NSColor(hex: 0x2A1A1E), 0), (NSColor(hex: 0x161624), 0.3),
                   (NSColor(hex: 0x0A0C16), 0.65), (NSColor(hex: 0x040509), 1))!
            .draw(in: NSRect(x: 0, y: h * 0.2, width: w, height: h * 0.8), angle: 90)
        for _ in 0..<Int(w * h / 4200) {
            let p = NSPoint(x: CGFloat.random(in: 0...w, using: &rng), y: CGFloat.random(in: h * 0.36...h, using: &rng))
            let r = CGFloat.random(in: 0.4...1.4, using: &rng)
            NSColor(hex: 0xEDE4D2, alpha: CGFloat.random(in: 0.1...0.85, using: &rng)).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x, y: p.y, width: r * 2, height: r * 2)).fill()
        }
        // The moon is the mark itself: a pale disc with the wolf cut out of it.
        let moon = h * 0.46
        let c = NSPoint(x: w * 0.66, y: h * 0.60)
        glow(at: c, radius: moon * 1.25, color: NSColor(hex: 0xB9C2D8), alpha: 0.30)
        draw("wolf", color: NSColor(hex: 0xE9E2D3), in: NSRect(x: c.x - moon / 2, y: c.y - moon / 2, width: moon, height: moon))
        // A low red haze: the mark of dishonor.
        NSGradient(colorsAndLocations: (NSColor(hex: 0x8C2A1E, alpha: 0.42), 0), (NSColor(hex: 0x8C2A1E, alpha: 0), 1))!
            .draw(in: NSRect(x: 0, y: h * 0.2, width: w, height: h * 0.3), angle: 90)
        let ridges: [(UInt32, CGFloat, CGFloat)] = [(0x1B1A26, 0.36, 0.09), (0x121119, 0.30, 0.07), (0x0A0A0F, 0.24, 0.05)]
        for (i, r) in ridges.enumerated() {
            ridge(w: w, h: h, base: h * r.1, amp: h * r.2, color: NSColor(hex: r.0), rng: &rng,
                  pines: i >= 1 ? 0.8 : 0.3, pineHeight: h * (0.04 + CGFloat(i) * 0.025), pineColor: NSColor(hex: r.0))
        }
        let ground = NSColor(hex: 0x040406)
        let rise = hill(w: w, h: h, peakX: 0.5, peakY: 0.15, color: ground)
        ground.setFill()
        var x: CGFloat = -10
        while x < w + 30 {
            let edge = abs(x / w - 0.5) * 2
            Scenery.pine(at: NSPoint(x: x, y: rise(x) - h * 0.02), height: h * CGFloat.random(in: 0.08...0.2, using: &rng) * (0.5 + edge), rng: &rng)
            x += CGFloat.random(in: 22...60, using: &rng)
        }
    }

    // MARK: Brushes

    private static func ridge(w: CGFloat, h: CGFloat, base: CGFloat, amp: CGFloat, color: NSColor, rng: inout SeededRNG,
                              pines: CGFloat, pineHeight: CGFloat, pineColor: NSColor) {
        let p1 = CGFloat.random(in: 0...6.28, using: &rng), p2 = CGFloat.random(in: 0...6.28, using: &rng)
        let f1 = CGFloat.random(in: 3...6, using: &rng), f2 = CGFloat.random(in: 9...15, using: &rng)
        func y(_ x: CGFloat) -> CGFloat {
            let u = x / w
            return base + amp * (0.6 * sin(u * f1 + p1) + 0.28 * sin(u * f2 + p2) + 0.12 * sin(u * 37 + p1 * 3))
        }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))
        var x: CGFloat = 0
        while x <= w + 6 { path.line(to: NSPoint(x: x, y: y(x))); x += 6 }
        path.line(to: NSPoint(x: w, y: 0))
        path.close()
        color.setFill()
        path.fill()
        guard pines > 0 else { return }
        pineColor.setFill()
        x = 0
        while x < w {
            if CGFloat.random(in: 0...1, using: &rng) < pines {
                Scenery.pine(at: NSPoint(x: x, y: y(x) - 2), height: pineHeight * CGFloat.random(in: 0.6...1.3, using: &rng), rng: &rng)
            }
            x += CGFloat.random(in: 10...28, using: &rng)
        }
    }

    /// Fills a broad foreground rise and returns its height function.
    private static func hill(w: CGFloat, h: CGFloat, peakX: CGFloat, peakY: CGFloat, color: NSColor) -> (CGFloat) -> CGFloat {
        let f: (CGFloat) -> CGFloat = { x in
            let u = x / w - peakX
            return h * (peakY - 0.16 * u * u + 0.012 * sin(u * 23) + 0.006 * sin(u * 61))
        }
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 0, y: 0))
        var x: CGFloat = 0
        while x <= w + 6 { path.line(to: NSPoint(x: x, y: f(x))); x += 6 }
        path.line(to: NSPoint(x: w, y: 0))
        path.close()
        color.setFill()
        path.fill()
        return f
    }

    private static func glow(at p: NSPoint, radius: CGFloat, color: NSColor, alpha: CGFloat) {
        NSGradient(colorsAndLocations: (color.withAlphaComponent(alpha), 0), (color.withAlphaComponent(alpha * 0.35), 0.4),
                   (color.withAlphaComponent(0), 1))!
            .draw(fromCenter: p, radius: 0, toCenter: p, radius: radius, options: [])
    }

    private static func vignette(_ s: CGSize, strength: CGFloat) {
        NSGradient(colorsAndLocations: (NSColor(white: 0, alpha: 0), 0), (NSColor(white: 0, alpha: 0), 0.5),
                   (NSColor(white: 0, alpha: strength), 1))!
            .draw(in: NSRect(origin: .zero, size: s), relativeCenterPosition: .zero)
    }

    /// Draws a template silhouette in a solid colour.
    static func draw(_ name: String, color: NSColor, in rect: NSRect) {
        let src = Res.art(name)
        let tinted = Paint.image(size: rect.size, scale: 2) {
            src.draw(in: NSRect(origin: .zero, size: rect.size))
            color.set()
            NSRect(origin: .zero, size: rect.size).fill(using: .sourceAtop)
        }
        tinted.draw(in: rect)
    }
}

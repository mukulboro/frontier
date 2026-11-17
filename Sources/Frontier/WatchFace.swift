import AppKit

/// The menu bar's pocket watch: a case with a crown, a hand that sweeps once per phase, and the
/// time still to run shaded in behind it.
enum WatchFace {
    /// The hand only has this many positions, so the icon is redrawn at most this often per phase
    /// rather than every second.
    static let steps = 120

    static func step(for progress: Double) -> Int {
        Int((min(1, max(0, progress)) * Double(steps)).rounded(.down))
    }

    static func image(step: Int, paused: Bool, resting: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let c = NSPoint(x: 9, y: 8)
            let r: CGFloat = 6.4
            let ink = NSColor.black
            // Crown and bow at twelve.
            ink.setFill()
            NSBezierPath(roundedRect: NSRect(x: 8.1, y: c.y + r + 0.3, width: 1.8, height: 1.5), xRadius: 0.4, yRadius: 0.4).fill()
            let bow = NSBezierPath(ovalIn: NSRect(x: 7.4, y: c.y + r + 1.4, width: 3.2, height: 2.2))
            bow.lineWidth = 0.9
            ink.setStroke()
            bow.stroke()

            // Time remaining: the wedge from the hand round to twelve.
            let progress = CGFloat(step) / CGFloat(steps)
            let handAngle = 90 - progress * 360                      // degrees, counter-clockwise from 3 o'clock
            if progress < 1 {
                let wedge = NSBezierPath()
                wedge.move(to: c)
                wedge.appendArc(withCenter: c, radius: r - 1.3, startAngle: handAngle, endAngle: 90 - 360, clockwise: true)
                wedge.close()
                ink.withAlphaComponent(paused ? 0.16 : 0.30).setFill()
                wedge.fill()
            }

            // Case. A rest is drawn with a dashed rim so it reads differently without colour.
            let rim = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
            rim.lineWidth = 1.3
            if resting { rim.setLineDash([2.2, 1.5], count: 2, phase: 0) }
            rim.stroke()

            // Hand.
            let rad = handAngle * .pi / 180
            let hand = NSBezierPath()
            hand.move(to: c)
            hand.line(to: NSPoint(x: c.x + cos(rad) * (r - 1.6), y: c.y + sin(rad) * (r - 1.6)))
            hand.lineWidth = 1.3
            hand.lineCapStyle = .round
            ink.withAlphaComponent(paused ? 0.5 : 1).setStroke()
            hand.stroke()
            NSBezierPath(ovalIn: NSRect(x: c.x - 1, y: c.y - 1, width: 2, height: 2)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

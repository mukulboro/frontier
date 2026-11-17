import AppKit
import SwiftUI

/// Locates bundled resources: inside the .app when packaged, the source tree during development.
enum Res {
    static let root: URL = {
        if let r = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: r.appendingPathComponent("Fonts").path) { return r }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Resources")
    }()

    static func url(_ path: String) -> URL { root.appendingPathComponent(path) }

    private static var imageCache: [String: NSImage] = [:]

    /// Drops cached silhouettes (and the bitmaps they were rasterised into at large sizes).
    static func flushArt() { imageCache.removeAll() }

    /// A silhouette from Resources/Art as a template image.
    static func art(_ name: String) -> NSImage {
        if let hit = imageCache[name] { return hit }
        let img = NSImage(contentsOf: url("Art/\(name).svg")) ?? NSImage()
        img.isTemplate = true
        imageCache[name] = img
        return img
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

/// Design tokens. Two surfaces only: the dark HUD and parchment.
enum Theme {
    enum NS {
        static let void = NSColor(hex: 0x0B0A08)
        static let surface = NSColor(hex: 0x141210)
        static let raised = NSColor(hex: 0x1E1B17)
        static let line = NSColor(hex: 0x2E2A24)
        static let paper = NSColor(hex: 0xE8DCC0)
        static let paperHi = NSColor(hex: 0xF2E8D2)
        static let paperLo = NSColor(hex: 0xC9B894)
        static let paperEdge = NSColor(hex: 0xA89374)
        static let ink = NSColor(hex: 0x241E16)
        static let inkSoft = NSColor(hex: 0x5A4A36)
        static let inkFaint = NSColor(hex: 0x8A7356)
        static let bone = NSColor(hex: 0xEDE4D2)
        static let boneDim = NSColor(hex: 0xB8AE9A)
        static let boneFaint = NSColor(hex: 0x6F675A)
        static let gold = NSColor(hex: 0xD8B15C)
        static let ochre = NSColor(hex: 0x8A5E1E)
        static let rustDark = NSColor(hex: 0x8C3A2B)
        static let rustLight = NSColor(hex: 0xCF5B50)
        static let sage = NSColor(hex: 0x6E7A5E)
    }

    static let void = Color(nsColor: NS.void)
    static let surface = Color(nsColor: NS.surface)
    static let raised = Color(nsColor: NS.raised)
    static let line = Color(nsColor: NS.line)
    static let paper = Color(nsColor: NS.paper)
    static let paperHi = Color(nsColor: NS.paperHi)
    static let paperLo = Color(nsColor: NS.paperLo)
    static let paperEdge = Color(nsColor: NS.paperEdge)
    static let ink = Color(nsColor: NS.ink)
    static let inkSoft = Color(nsColor: NS.inkSoft)
    static let inkFaint = Color(nsColor: NS.inkFaint)
    static let bone = Color(nsColor: NS.bone)
    static let boneDim = Color(nsColor: NS.boneDim)
    static let boneFaint = Color(nsColor: NS.boneFaint)
    static let gold = Color(nsColor: NS.gold)
    static let ochre = Color(nsColor: NS.ochre)
    static let rustDark = Color(nsColor: NS.rustDark)
    static let rustLight = Color(nsColor: NS.rustLight)
    static let sage = Color(nsColor: NS.sage)

    static let settle = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.22)
    static let honorGlide = Animation.timingCurve(0.22, 0.61, 0.36, 1, duration: 0.9)

    static let displayFamily = "Big Shoulders Display"
    static let westernFamily = "Rye"
    static let bodyFamily = "Lora"
    static let handFamily = "Caveat"

    static func registerFonts() {
        let dir = Res.url("Fonts")
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
        }
    }

    static func display(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .custom(displayFamily, fixedSize: size).weight(weight)
    }
    static func western(_ size: CGFloat) -> Font { .custom(westernFamily, fixedSize: size) }
    static func body(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(bodyFamily, fixedSize: size).weight(weight)
    }
    static func hand(_ size: CGFloat) -> Font { .custom(handFamily, fixedSize: size).weight(.semibold) }

    static func nsDisplay(_ size: CGFloat, weight: NSFont.Weight = .bold) -> NSFont {
        let desc = NSFontDescriptor(fontAttributes: [
            .family: displayFamily,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
        ])
        return NSFont(descriptor: desc, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}

/// UPPERCASE, wide-tracked HUD label — the signature of the interface.
struct HUDLabel: View {
    let text: String
    var size: CGFloat = 12
    var color: Color = Theme.bone

    var body: some View {
        Text(text.uppercased())
            .font(Theme.display(size, .bold))
            .tracking(size * 0.14)
            .foregroundStyle(color)
    }
}

/// A silhouette from Resources/Art, tinted.
struct ArtGlyph: View {
    let name: String
    var color: Color = Theme.bone

    var body: some View {
        Image(nsImage: Res.art(name))
            .renderingMode(.template)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(color)
    }
}

func formatClock(_ t: TimeInterval) -> String {
    let s = max(0, Int(t.rounded(.up)))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                     : String(format: "%02d:%02d", s / 60, s % 60)
}

enum Paint {
    /// Draws straight into an IOSurface, which a CALayer can show as-is. For screen-sized art this is
    /// the difference between one buffer and three: no bitmap in the heap, and no private copy made by
    /// Core Animation, because the compositor reads the very same surface.
    static func surface(size: CGSize, scale: CGFloat, _ draw: () -> Void) -> IOSurface? {
        let pw = max(1, Int((size.width * scale).rounded())), ph = max(1, Int((size.height * scale).rounded()))
        guard let surface = IOSurface(properties: [.width: pw, .height: ph, .bytesPerElement: 4,
                                                   .pixelFormat: UInt32(0x42475241)]) else { return nil }   // 'BGRA'
        surface.lock(options: [], seed: nil)
        defer { surface.unlock(options: [], seed: nil) }
        let info = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let cg = CGContext(data: surface.baseAddress, width: pw, height: ph, bitsPerComponent: 8,
                                 bytesPerRow: surface.bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 bitmapInfo: info) else { return nil }
        cg.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return surface
    }

    /// Draws into an 8-bit sRGB bitmap of exactly `size × scale` pixels. Unlike `lockFocus`, this never
    /// allocates a deep (16-bit) or over-sized backing store, which matters for screen-sized art.
    static func image(size: CGSize, scale: CGFloat = 1, _ draw: () -> Void) -> NSImage {
        let pw = max(1, Int((size.width * scale).rounded())), ph = max(1, Int((size.height * scale).rounded()))
        let img = NSImage(size: size)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pw, pixelsHigh: ph, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return img }
        rep.size = size     // must be set before the context is made: that's where it reads the scale from
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return img }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        draw()
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        img.addRepresentation(rep)
        return img
    }
}

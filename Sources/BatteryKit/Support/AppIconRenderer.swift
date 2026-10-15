import Foundation
import CoreGraphics
import ImageIO

/// Draws the app icon procedurally.
///
/// Generating it in code (rather than shipping a binary asset) keeps the repository free of
/// opaque blobs and lets the icon be rendered at exactly the pixel sizes `iconutil` wants,
/// with no resampling artefacts. Uses only CoreGraphics + ImageIO, so `BatteryKit` stays free
/// of any UI framework.
public enum AppIconRenderer {

    /// The exact `AppIcon.iconset` contents `iconutil` expects: file name → pixel size.
    public static let iconsetContents: [(name: String, size: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    public static func pngData(size: Int) -> Data? {
        guard size > 0,
              let context = CGContext(data: nil,
                                      width: size,
                                      height: size,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        draw(in: context, size: CGFloat(size))

        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// Writes a complete `.iconset` directory ready for `iconutil -c icns`.
    @discardableResult
    public static func writeIconset(to directory: URL) throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var written = 0
        for entry in iconsetContents {
            guard let data = pngData(size: entry.size) else { continue }
            try data.write(to: directory.appendingPathComponent(entry.name))
            written += 1
        }
        return written
    }

    // MARK: - Drawing

    private static func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
        CGColor(srgbRed: r, green: g, blue: b, alpha: a)
    }

    private static func draw(in ctx: CGContext, size S: CGFloat) {
        ctx.setAllowsAntialiasing(true)
        ctx.interpolationQuality = .high

        // ── Rounded-square background ──────────────────────────────────────────────────────
        //
        // Dark slate rather than the green the previous icon used. A green square with a white
        // battery and a bolt is the icon of every battery utility on the platform; the thing that
        // is actually distinctive about this app is the ring gauge its whole interface is built
        // from, so that becomes the mark and the background gets out of its way.
        let inset = S * 0.055
        let rect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
        let corner = rect.width * 0.225
        let background = CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)

        ctx.saveGState()
        ctx.addPath(background)
        ctx.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [color(0.129, 0.157, 0.196),
                                              color(0.043, 0.055, 0.071)] as CFArray,
                                     locations: [0, 1]) {
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: rect.midX, y: rect.maxY),
                                   end: CGPoint(x: rect.midX, y: rect.minY),
                                   options: [])
        }
        // A soft green bloom behind the ring, so the dark ground reads as depth rather than as a
        // flat black square at small sizes.
        if let bloom = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                  colors: [color(0.24, 0.86, 0.52, 0.30),
                                           color(0.24, 0.86, 0.52, 0)] as CFArray,
                                  locations: [0, 1]) {
            ctx.drawRadialGradient(bloom,
                                   startCenter: CGPoint(x: rect.midX, y: rect.midY), startRadius: 0,
                                   endCenter: CGPoint(x: rect.midX, y: rect.midY), endRadius: rect.width * 0.55,
                                   options: [])
        }
        // Glassy rim: brighter along the top edge only.
        ctx.addPath(background)
        ctx.setLineWidth(S * 0.006)
        ctx.setStrokeColor(color(1, 1, 1, 0.10))
        ctx.strokePath()
        ctx.restoreGState()

        // ── Ring gauge ─────────────────────────────────────────────────────────────────────
        //
        // 270° of arc with the gap at the bottom: a gauge, not a circle. The same shape the
        // health and cycle rings use inside the app.
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width * 0.302
        let thickness = rect.width * 0.126
        // In this (y-up) space 270° points down, so start at 225° and sweep clockwise to −45°.
        let startAngle = CGFloat.pi * 1.25
        let endAngle = -CGFloat.pi * 0.25

        ctx.setLineCap(.round)
        ctx.setLineWidth(thickness)
        ctx.setStrokeColor(color(1, 1, 1, 0.10))
        ctx.addArc(center: centre, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()

        ctx.saveGState()
        ctx.addArc(center: centre, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: true)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                     colors: [color(0.078, 0.722, 0.651),
                                              color(0.239, 0.863, 0.518)] as CFArray,
                                     locations: [0, 1]) {
            ctx.drawLinearGradient(gradient,
                                   start: CGPoint(x: rect.minX, y: rect.minY),
                                   end: CGPoint(x: rect.maxX, y: rect.maxY),
                                   options: [])
        }
        ctx.restoreGState()

        // ── Battery, inside the ring ───────────────────────────────────────────────────────
        //
        // Bold on purpose: this has to survive being drawn at 32 pt in the Dock.
        // Sized so the battery occupies under half the ring's interior. At 0.335 it touched the
        // ring on both sides and the two shapes merged into one blob when drawn at Dock sizes.
        let bodyHeight = rect.width * 0.152
        let bodyWidth = rect.width * 0.238
        let nubWidth = rect.width * 0.028
        let totalWidth = bodyWidth + nubWidth + rect.width * 0.018
        let bodyRect = CGRect(x: centre.x - totalWidth / 2,
                              y: centre.y - bodyHeight / 2,
                              width: bodyWidth,
                              height: bodyHeight)
        let shell = CGPath(roundedRect: bodyRect,
                           cornerWidth: bodyHeight * 0.30, cornerHeight: bodyHeight * 0.30,
                           transform: nil)

        ctx.addPath(shell)
        ctx.setLineWidth(rect.width * 0.020)
        ctx.setStrokeColor(color(1, 1, 1, 0.92))
        ctx.strokePath()

        // Terminal nub.
        let nubHeight = bodyHeight * 0.42
        let nubRect = CGRect(x: bodyRect.maxX + rect.width * 0.008,
                             y: centre.y - nubHeight / 2,
                             width: nubWidth,
                             height: nubHeight)
        ctx.addPath(CGPath(roundedRect: nubRect,
                           cornerWidth: nubWidth * 0.4, cornerHeight: nubWidth * 0.4,
                           transform: nil))
        ctx.setFillColor(color(1, 1, 1, 0.92))
        ctx.fillPath()

        // Charge level, ~68 %, which is what most battery UIs show and reads as "in use" rather
        // than as the "charging" a bolt would imply.
        let pad = rect.width * 0.030
        let inner = bodyRect.insetBy(dx: pad, dy: pad)
        let fillRect = CGRect(x: inner.minX, y: inner.minY,
                              width: inner.width * 0.68, height: inner.height)
        ctx.addPath(CGPath(roundedRect: fillRect,
                           cornerWidth: inner.height * 0.28, cornerHeight: inner.height * 0.28,
                           transform: nil))
        ctx.setFillColor(color(1, 1, 1, 1))
        ctx.fillPath()
    }
}

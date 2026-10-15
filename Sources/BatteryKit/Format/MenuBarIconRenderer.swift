import AppKit

/// Draws the menu-bar glyph.
///
/// There is exactly one look: the continuous-fill battery outline, coloured the way macOS colours
/// its own item — monochrome in the menu bar's own colour, switching to amber/red only for a charge
/// worth warning about. There is no style or palette to choose, so there are no such options here.
///
/// The glyph is drawn rather than taken from SF Symbols so the fill level can be continuous (73%
/// looks like 73%, not like the nearest of five symbols) and so a reading can sit *inside* the
/// outline. That slot holds either the percentage or the remaining time; the two are mutually
/// exclusive and both may be absent.
///
/// This type lives in `BatteryKit` so its output can be tested by inspecting actual pixels: the
/// charge bolt is invisible in a template image unless it is punched out of the fill, and that is
/// not something a test of the drawing code would otherwise catch.
public enum MenuBarIconRenderer {

    /// Glyph with nothing inside the outline.
    public static let glyphSize = NSSize(width: 26, height: 13)

    private static let bodyHeightPlain: CGFloat = 11
    private static let bodyHeightWithText: CGFloat = 12
    private static let textPadding: CGFloat = 6
    private static let maximumBodyWidth: CGFloat = 27
    private static let maximumTextWidth: CGFloat = 22
    /// The width the outline always uses, sized for the widest reading (`100%`) at the base font.
    ///
    /// Keeping it constant matters for more than tidiness: the status item's frame would otherwise
    /// change when the content changes, which shifts the item (and every item left of it) and
    /// leaves an already-open popover anchored to the old rectangle. Sized from `100%` so it is
    /// still the narrowest outline that never has to shrink the text.
    private static let constantBodyWidth: CGFloat = {
        var fontSize = baseFontSize
        var width = attributedText("100%", fontSize: fontSize, color: .black).size().width
        while fontSize > minimumFontSize, width > maximumTextWidth {
            fontSize -= 0.25
            width = attributedText("100%", fontSize: fontSize, color: .black).size().width
        }
        return Swift.min(maximumBodyWidth, width + textPadding)
    }()
    private static let baseFontSize: CGFloat = 6.0
    private static let minimumFontSize: CGFloat = 5.25

    // MARK: - Palette

    private static let chargingColor = NSColor(calibratedRed: 0.20, green: 0.72, blue: 0.35, alpha: 1)
    private static let lowColor = NSColor(calibratedRed: 0.95, green: 0.68, blue: 0.13, alpha: 1)
    private static let criticalColor = NSColor(calibratedRed: 0.93, green: 0.27, blue: 0.24, alpha: 1)

    private static func criticalThreshold(_ lowBatteryThreshold: Double) -> Double {
        Swift.max(10, lowBatteryThreshold / 2)
    }

    /// The colour for a charge worth warning about, or `nil` when the glyph should stay monochrome.
    ///
    /// A low or critical charge outranks everything else, including "charging" — a battery at 8%
    /// while plugged in is still worth showing in red.
    public static func warningColor(percent: Double?, lowBatteryThreshold: Double) -> NSColor? {
        guard let percent else { return nil }
        if percent <= criticalThreshold(lowBatteryThreshold) { return criticalColor }
        if percent <= lowBatteryThreshold { return lowColor }
        return nil
    }

    /// The colour the whole glyph is drawn in, or `nil` to stay monochrome in the menu bar's own
    /// colour.
    ///
    /// Warning colours win. Otherwise the battery turns green whenever **a charger is attached** —
    /// not only while current is actually flowing into the cell. macOS frequently sits at "AC
    /// attached; not charging" (holding a charge level), and gating the colour on `isCharging` meant
    /// plugging in produced no visible change at all. Green therefore follows the same rule as the
    /// bolt: it means "on external power".
    public static func accentColor(percent: Double?,
                                   isCharging: Bool,
                                   externalConnected: Bool,
                                   lowBatteryThreshold: Double) -> NSColor? {
        if let warning = warningColor(percent: percent, lowBatteryThreshold: lowBatteryThreshold) {
            return warning
        }
        return (isCharging || externalConnected) ? chargingColor : nil
    }

    /// Colour for the reading inside the outline, so a low battery reads red rather than grey.
    public static func labelColor(percent: Double?,
                                  externalConnected: Bool,
                                  lowBatteryThreshold: Double) -> NSColor? {
        warningColor(percent: percent, lowBatteryThreshold: lowBatteryThreshold)
    }



    // MARK: - Text metrics

    /// The reading carries its own colour: the drawing routine cuts the glyphs out of the fill when
    /// they overlap it, but where they sit on the empty part of the battery they are painted in this
    /// colour — so it has to be the accent colour, not always black.
    private static func attributedText(_ string: String,
                                       fontSize: CGFloat,
                                       color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: color,
        ])
    }

    /// Shrinks the font until the reading fits the slot, so `10h 45m` does not spill out of a
    /// battery sized for `97%`.
    private static func fitted(_ text: String,
                               color: NSColor) -> (attributed: NSAttributedString,
                                                   fontSize: CGFloat,
                                                   bodyWidth: CGFloat,
                                                   lineHeight: CGFloat) {
        var fontSize = baseFontSize
        var attributed = attributedText(text, fontSize: fontSize, color: color)
        while fontSize > minimumFontSize, attributed.size().width > maximumTextWidth {
            fontSize -= 0.25
            attributed = attributedText(text, fontSize: fontSize, color: color)
        }
        let width = Swift.min(maximumBodyWidth, Swift.max(24, attributed.size().width + textPadding))
        return (attributed, fontSize, width, attributed.size().height)
    }

    // MARK: - Image

    /// - Parameter iconText: what to draw inside the outline — the percentage, the remaining time,
    ///   or `nil` for nothing. Only one reading is ever shown, because there is only one slot.
    public static func image(percent: Double?,
                             isCharging: Bool,
                             externalConnected: Bool,
                             iconText: String?,
                             lowBatteryThreshold: Double = 20) -> NSImage {
        // Monochrome unless there is a colour worth showing: a template image is masked to the
        // menu bar's own colour, which is how macOS draws its battery item at rest. Charging turns
        // it green, and a low or critical charge turns it amber or red.
        let accent = accentColor(percent: percent,
                                 isCharging: isCharging,
                                 externalConnected: externalConnected,
                                 lowBatteryThreshold: lowBatteryThreshold)
        let monochrome = accent == nil
        // The bolt tracks the charger, not the charging: it stays visible when the battery is full
        // or a charge limit has paused charging, which is how macOS draws it.
        let showsBolt = MenuBarIconState.showsBolt(externalConnected: externalConnected,
                                                   isCharging: isCharging)
        return batteryGlyph(percent: percent,
                            showsBolt: showsBolt,
                            iconText: iconText,
                            accent: accent,
                            monochrome: monochrome)
    }

    // MARK: - Glyph

    private static func fillFraction(for percent: Double?) -> Double {
        guard let percent else { return 0 }
        return Swift.max(0, Swift.min(1, percent / 100))
    }

    private static func batteryGlyph(percent: Double?,
                                     showsBolt: Bool,
                                     iconText: String?,
                                     accent: NSColor?,
                                     monochrome: Bool) -> NSImage {
        let reading = iconText.map { fitted($0, color: accent ?? .black) }
        // The outline is always the same size, whether it holds a reading, a bolt, or nothing.
        let bodyHeight = bodyHeightWithText
        let bodyWidth = constantBodyWidth
        // Taller than the body so the bolt tips can reach past the outline without being clipped.
        let imageSize = NSSize(width: bodyWidth + 3.2, height: 15)
        let inset: CGFloat = 1.3

        let image = NSImage(size: imageSize, flipped: false) { _ in
            let capWidth: CGFloat = 2.0
            let originY = (imageSize.height - bodyHeight) / 2
            let bodyRect = NSRect(x: 0.5, y: originY, width: bodyWidth, height: bodyHeight)

            // A template image is masked to the menu bar's own colour, so any opaque colour works
            // and the result adapts to light/dark automatically. When there is an accent colour the
            // outline takes it too, so the whole battery reads as one green/amber/red icon rather
            // than a grey shell around a coloured bar.
            let outline: NSColor = accent ?? .black
            let fill: NSColor = accent ?? .black

            let capRect = NSRect(x: bodyRect.maxX + 0.5,
                                 y: originY + bodyHeight * 0.28,
                                 width: capWidth,
                                 height: bodyHeight * 0.44)
            outline.setFill()
            NSBezierPath(roundedRect: capRect, xRadius: 0.9, yRadius: 0.9).fill()

            let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 3, yRadius: 3)
            bodyPath.lineWidth = 1.1
            outline.setStroke()
            bodyPath.stroke()

            let interior = bodyRect.insetBy(dx: inset, dy: inset)
            let fraction = fillFraction(for: percent)
            var fillRect = NSRect(x: interior.minX, y: interior.minY, width: 0, height: interior.height)
            if fraction > 0.001 {
                let width = Swift.max(1.2, interior.width * CGFloat(fraction))
                fillRect = NSRect(x: interior.minX, y: interior.minY,
                                  width: width, height: interior.height)
                fill.setFill()
                NSBezierPath(roundedRect: fillRect,
                             xRadius: Swift.min(inset, width / 2),
                             yRadius: Swift.min(inset, width / 2)).fill()
            }

            let context = NSGraphicsContext.current?.cgContext

            // A reading and a bolt never appear together: the bolt means a charger is attached, and
            // then there is no reading to show. Either one is centred on its own.
            if let reading {
                drawReading(reading.attributed, region: bodyRect, bodyRect: bodyRect,
                            fillRect: fillRect, color: outline, context: context)
            }

            if showsBolt {
                drawBolt(in: bodyRect, monochrome: monochrome)
            }

            return true
        }
        image.isTemplate = monochrome
        return image
    }

    /// Draws the reading inside the battery outline, erasing it out of the filled part.
    ///
    /// Where the text overlaps the fill it is cut out of it (so the menu bar shows through the
    /// glyphs), and where it sits on the empty part it is drawn opaquely. That keeps the reading
    /// legible at every charge level without needing a plate behind it.
    private static func drawReading(_ attributed: NSAttributedString,
                                    region: NSRect,
                                    bodyRect: NSRect,
                                    fillRect: NSRect,
                                    color: NSColor,
                                    context: CGContext?) {
        let textSize = attributed.size()
        let origin = NSPoint(x: region.midX - textSize.width / 2,
                             y: region.midY - textSize.height / 2)
        guard let context else {
            attributed.draw(at: origin)
            return
        }

        if fillRect.width > 1 {
            context.saveGState()
            context.clip(to: fillRect)
            context.setBlendMode(.clear)
            attributed.draw(at: origin)
            context.restoreGState()
        }

        // Everything inside the body except the filled part, using even-odd so the two rects
        // cancel where they overlap.
        let rest = NSBezierPath(rect: bodyRect.insetBy(dx: -0.6, dy: -0.6))
        if fillRect.width > 1 { rest.append(NSBezierPath(rect: fillRect)) }
        rest.windingRule = .evenOdd
        context.saveGState()
        rest.addClip()
        context.setBlendMode(.normal)
        attributed.draw(at: origin)
        context.restoreGState()
    }

    /// Draws the charge bolt, lying **horizontally** inside the battery.
    ///
    /// A vertical bolt fights the glyph: the battery outline is roughly twice as wide as it is
    /// tall, so an upright bolt either looks pinched or has to burst past the edges to reach a
    /// sensible size. Drawn sideways it fills the outline evenly, stays inside it, and still reads
    /// as a lightning bolt. The path is built upright and rotated a quarter turn, so the silhouette
    /// stays a real bolt rather than a hand-fitted approximation.
    private static func drawBolt(in zone: NSRect, monochrome: Bool) {
        let cx = zone.midX
        let cy = zone.midY
        // The bolt's long axis ends up horizontal, so it is bounded by the body's width; the short
        // axis has to stay well inside the body's height.
        let length: CGFloat = Swift.min(zone.width * 0.56, zone.height * 1.10)
        let width: CGFloat = length * 0.46
        // Every offset is a fraction of the bolt's own size, so changing the size scales the whole
        // silhouette instead of distorting the waist. The middle jog is kept shallow so the two
        // halves meet in a crisp edge rather than a band.
        let halfWidth = width / 2
        let waistInset = width * 0.077
        let waistOffset = length * 0.018

        let bolt = NSBezierPath()
        bolt.move(to: NSPoint(x: cx + waistInset, y: cy + length / 2))
        bolt.line(to: NSPoint(x: cx - halfWidth, y: cy - waistOffset))
        bolt.line(to: NSPoint(x: cx - waistInset / 2, y: cy - waistOffset))
        bolt.line(to: NSPoint(x: cx - waistInset, y: cy - length / 2))
        bolt.line(to: NSPoint(x: cx + halfWidth, y: cy + waistOffset))
        bolt.line(to: NSPoint(x: cx + waistInset / 2, y: cy + waistOffset))
        bolt.close()
        bolt.lineJoinStyle = .round

        // Lay it on its side, tip pointing right.
        var rotation = AffineTransform()
        rotation.translate(x: cx, y: cy)
        rotation.rotate(byDegrees: -90)
        rotation.translate(x: -cx, y: -cy)
        bolt.transform(using: rotation)

        // Opaque, with no halo: the bolt only ever sits on a coloured battery (external power is
        // always green, or a warning colour), and white separates cleanly from those. Monochrome is
        // kept as a fallback in case the colour policy ever stops covering every bolt case.
        (monochrome ? NSColor.black : NSColor.white).setFill()
        bolt.fill()
    }
}

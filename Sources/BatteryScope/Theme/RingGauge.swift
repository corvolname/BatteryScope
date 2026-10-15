import SwiftUI
import BatteryKit

/// A horizontal capacity bar, in the style of the system battery indicator: a translucent track
/// plus a solid fill. Used on the card in place of a ring so the reading matches what macOS
/// users already recognise.
struct CapacityBar: View {
    let fraction: Double
    var color: Color = .primary
    var height: CGFloat = 11
    /// Moving diagonal stripes while the battery is taking on charge, the same visual language
    /// macOS uses for work in progress: it reads as "filling" rather than as the level changing.
    var isPulsing: Bool = false

    private var clamped: Double { Swift.max(0, Swift.min(1, fraction)) }

    var body: some View {
        GeometryReader { geometry in
            let fillWidth = Swift.max(height, geometry.size.width * CGFloat(clamped))
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.13))

                if isPulsing {
                    // Driven by the display link rather than by a state toggle: a
                    // `repeatForever` animation started from `onAppear` gets cancelled by the
                    // 1-second snapshot refresh that rebuilds this view, which left the bar
                    // frozen at a single opacity.
                    // 12 fps, not 30: the stripes slide slowly enough that the extra frames were
                    // pure cost — this view redraws forever while the card is open.
                    TimelineView(.animation(minimumInterval: 1.0 / 12.0)) { context in
                        StripedFill(color: color,
                                    phase: Self.stripePhase(at: context.date))
                    }
                    .frame(width: fillWidth, height: geometry.size.height)
                } else {
                    Capsule(style: .continuous)
                        .fill(color)
                        .frame(width: fillWidth)
                }
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.3), value: clamped)
    }

    /// Stripes advance by exactly one spacing per 0.8 s, so the loop is seamless.
    private static func stripePhase(at date: Date) -> Double {
        let period = 0.8
        let seconds = date.timeIntervalSinceReferenceDate
        return (seconds.truncatingRemainder(dividingBy: period)) / period
    }
}

/// The filled portion with diagonal stripes sliding through it.
private struct StripedFill: View {
    let color: Color
    let phase: Double

    private let stripeWidth: CGFloat = 6
    private let spacing: CGFloat = 13

    var body: some View {
        Canvas { context, size in
            let shape = Path(roundedRect: CGRect(origin: .zero, size: size),
                             cornerRadius: size.height / 2)
            context.fill(shape, with: .color(color))
            context.clip(to: shape)

            // The stripe band is sheared by one bar-height so the stripes are diagonal; the
            // leading edge starts off-canvas so the pattern slides in rather than appearing.
            let offset = CGFloat(phase) * spacing
            var x = -size.height - spacing + offset
            while x < size.width + size.height {
                var stripe = Path()
                stripe.move(to: CGPoint(x: x, y: size.height))
                stripe.addLine(to: CGPoint(x: x + size.height, y: 0))
                stripe.addLine(to: CGPoint(x: x + size.height + stripeWidth, y: 0))
                stripe.addLine(to: CGPoint(x: x + stripeWidth, y: size.height))
                stripe.closeSubpath()
                context.fill(stripe, with: .color(.white.opacity(0.22)))
                x += spacing
            }
        }
    }
}

/// A circular progress gauge with arbitrary centre content.
///
/// The track is a full circle and the value a trimmed arc, which keeps the stroke caps round at
/// both ends without any manual geometry.
struct RingGauge<Content: View>: View {
    var progress: Double
    var lineWidth: CGFloat = 11
    var color: Color
    var trackOpacity: Double = 0.13
    @ViewBuilder var content: () -> Content

    private var clamped: Double { Swift.max(0, Swift.min(1, progress)) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(trackOpacity),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            Circle()
                .trim(from: 0, to: CGFloat(clamped))
                .stroke(color,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.35), value: clamped)
            content()
        }
        .padding(lineWidth / 2)
    }
}

/// The headline charge gauge used in the detail window.
struct ChargeRing: View {
    let percent: Double?
    let color: Color
    var size: CGFloat = 108
    var lineWidth: CGFloat = 11

    /// The ring is a circle, so the usable width shrinks towards its top and bottom: content sized
    /// to the full diameter spills over the stroke. The reading is therefore width-constrained to
    /// the interior and allowed to scale down instead.
    private var interiorWidth: CGFloat { size - lineWidth * 2 - 8 }

    var body: some View {
        // Just the percentage. The ring used to carry a second line inside it — a bolt plus
        // "正在充电" — sitting immediately beside the header's own text saying exactly that. The
        // status is already stated once, in words, so the ring states the number.
        RingGauge(progress: (percent ?? 0) / 100, lineWidth: lineWidth, color: color) {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(percent.map { String(format: "%.0f", $0) } ?? "—")
                    .font(.system(size: size * 0.30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("%")
                    .font(.system(size: size * 0.13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .frame(maxWidth: interiorWidth)
        }
        .frame(width: size, height: size)
    }
}

/// A secondary ring for a value with a natural 0–100 range, such as health.
struct SmallRing: View {
    let title: String
    let percent: Double?
    let color: Color
    var size: CGFloat = 78
    var lineWidth: CGFloat = 8
    var centerText: String?
    var caption: String?

    var body: some View {
        VStack(spacing: 5) {
            RingGauge(progress: (percent ?? 0) / 100, lineWidth: lineWidth, color: color) {
                VStack(spacing: 0) {
                    Text(centerText ?? percent.map { String(format: "%.0f%%", $0) } ?? "—")
                        .font(.system(size: size * 0.24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    if let caption {
                        Text(caption)
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(width: size, height: size)
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

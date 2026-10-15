import SwiftUI
import BatteryKit

/// Shared visual language.
///
/// The app follows macOS conventions: neutral system colours for chrome, with colour reserved
/// for state that actually matters (charging, low charge, critical charge) and for distinguishing
/// data series in a chart, where colour carries information rather than decoration.
enum Theme {

    /// Group-card corner radius. macOS 27's System Settings groups sit at roughly this curvature;
    /// the previous 10 read as a small control rather than a content group.
    static let corner: CGFloat = 14
    /// Padding inside a group card. Inner rounded elements should use a radius of
    /// `corner - cardPadding` so the curves stay concentric.
    static let cardPadding: CGFloat = 14

    // MARK: State colours (matched to the menu bar icon)

    static let charging = Color(nsColor: .systemGreen)
    static let onAC = Color(nsColor: .systemBlue)
    static let lowBattery = Color(nsColor: .systemYellow)
    static let critical = Color(nsColor: .systemRed)
    static let advisory = Color(nsColor: .systemYellow)

    // MARK: Data-series colours (detail charts only)

    static let seriesCharge = Color(nsColor: .systemGreen)
    static let seriesBatteryPower = Color(nsColor: .systemBlue)
    static let seriesSystemLoad = Color(nsColor: .systemOrange)
    static let seriesAdapterPower = Color(nsColor: .systemPurple)
    static let seriesTemperature = Color(nsColor: .systemRed)
    static let seriesChipTemperature = Color(nsColor: .systemPink)
    static let seriesCapacity = Color(nsColor: .systemTeal)
    static let seriesVoltage = Color(nsColor: .systemIndigo)
    static let seriesHealth = Color(nsColor: .systemMint)

    /// Colour for a charge level when the battery is actually powering the machine.
    static func chargeColor(percent: Double?) -> Color {
        guard let percent else { return .secondary }
        if percent <= 10 { return critical }
        if percent <= 20 { return lowBattery }
        return .primary
    }

    /// The colour that represents "what is happening right now".
    static func statusColor(_ snapshot: BatterySnapshot?) -> Color {
        guard let snapshot else { return .secondary }
        if let percent = snapshot.chargePercent, percent <= 20 {
            return percent <= 10 ? critical : lowBattery
        }
        if snapshot.isCharging { return charging }
        if snapshot.externalConnected { return onAC }
        return .primary
    }

    /// Two states, split at 80 %.
    ///
    /// 80 % is the boundary macOS itself uses: below it a battery is reported as needing service,
    /// and System Settings marks that state in yellow. Above it there is nothing to warn about, so
    /// the colour is the plain healthy green. The previous three-way split (red under 80, amber
    /// under 90, green above) invented an 80–90 % warning band that the system does not have, and
    /// painted a perfectly healthy 89 % battery amber.
    static func healthColor(_ percent: Double?) -> Color {
        guard let percent else { return .secondary }
        return percent < 80 ? lowBattery : charging
    }

    static func metricColor(_ metric: SampleMetric) -> Color {
        switch metric {
        case .chargePercent: return seriesCharge
        case .power: return seriesBatteryPower
        case .systemLoad: return seriesSystemLoad
        case .adapterPower: return seriesAdapterPower
        case .cpuTemperature: return seriesChipTemperature
        case .gpuTemperature: return Color(nsColor: .systemPurple)
        case .temperature: return seriesTemperature
        case .capacity: return seriesCapacity
        case .voltage: return seriesVoltage
        case .healthPercent: return seriesHealth
        // The load readings get their own three colours so a chart is identifiable by colour alone.
        case .cpuLoad: return Color(nsColor: .systemIndigo)
        case .gpuLoad: return Color(nsColor: .systemTeal)
        case .memory: return Color(nsColor: .systemBrown)
        case .fanRPM: return Color(nsColor: .systemMint)
        case .batteryCurrent: return Color(nsColor: .systemOrange)
        }
    }
}

/// A subtle grouped container for the detail window.
struct SectionCard<Content: View>: View {
    var title: String?
    var systemImage: String?
    var accent: Color = .secondary
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                // Above the card rather than inside it, and inset to line up with the card's
                // content instead of its edge — this is how macOS 27's System Settings labels a
                // group ("电池健康" sits above its sheet, not in it).
                HStack(spacing: 5) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 4)
            }
            content()
                .padding(Theme.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.corner, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
            // No stroke: the current macOS groups separate themselves by fill alone, and the
            // hairline made the card look like a control rather than a group.
        }
    }
}

/// One label/value pair with an optional explanatory note.
struct KeyValueRow: View {
    let label: String
    let value: String
    var note: String?
    var valueColor: Color = .primary
    /// Keep the row to a single line, truncating rather than wrapping.
    ///
    /// Set by the detail window's cards. Two cards sitting side by side only line up row for row if
    /// every row is the same height, and one long value — USB-PD 档位 listed four contracts — was
    /// enough to push every row below it out of step. Truncating is the lesser evil: a clipped tail
    /// is visible as such, whereas a shifted column reads as a mistake.
    var singleLine: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // The provenance note sits under the *label*, left-aligned, rather than under the value.
            //
            // Under the value it was right-aligned, so a long register name such as
            // `AppleRawMaxCapacity / FullChargeCapacity` began mid-row under a short value like
            // `89.5 %`, and every row's note started at a different x. Reading it as a sub-label of
            // the thing being measured is both tidier and more accurate: the note names where the
            // number came from, not what it is.
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(singleLine ? 1 : nil)
                    .fixedSize(horizontal: false, vertical: !singleLine)
                if let note, !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(singleLine ? 1 : nil)
                .textSelection(.enabled)
        }
    }
}

/// The compact live chart used inside the popover. Hand-drawn with `Canvas` so it stays cheap
/// enough to redraw on every sample tick.
struct Sparkline: View {
    let points: [ChartPoint]
    var color: Color = .accentColor
    var baseline: Double?
    var lineWidth: CGFloat = 1.6
    var showsArea: Bool = true
    /// Floor on the visible vertical span, so noise is not stretched to full height.
    var minimumSpan: Double = 0

    var body: some View {
        Canvas { context, size in
            guard points.count >= 2 else { return }
            let values = points.map(\.value)
            var lower = values.min() ?? 0
            var upper = values.max() ?? 1
            if let baseline {
                lower = Swift.min(lower, baseline)
                upper = Swift.max(upper, baseline)
            }
            guard upper.isFinite, lower.isFinite else { return }

            let midpoint = (lower + upper) / 2
            if upper - lower < minimumSpan {
                lower = midpoint - minimumSpan / 2
                upper = midpoint + minimumSpan / 2
                if let baseline, baseline < lower || baseline > upper {
                    lower = Swift.min(lower, baseline)
                    upper = Swift.max(upper, baseline)
                }
            }
            if upper - lower < 0.0001 { upper = lower + 1 }
            let padding = (upper - lower) * 0.10
            lower -= padding
            upper += padding
            let span = upper - lower

            func position(_ index: Int) -> CGPoint {
                let x = size.width * CGFloat(index) / CGFloat(Swift.max(1, points.count - 1))
                let normalized = (points[index].value - lower) / span
                return CGPoint(x: x, y: size.height * (1 - CGFloat(normalized)))
            }

            var line = Path()
            line.move(to: position(0))
            for index in 1..<points.count { line.addLine(to: position(index)) }

            if let baseline {
                let normalized = (baseline - lower) / span
                let y = size.height * (1 - CGFloat(normalized))
                var axis = Path()
                axis.move(to: CGPoint(x: 0, y: y))
                axis.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(axis, with: .color(Color.secondary.opacity(0.30)),
                               style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            if showsArea {
                // When a zero baseline is shown, the fill closes onto that line rather than onto
                // the bottom of the box. Filling below zero on a power chart would read as
                // "negative power" for values that are simply above the baseline.
                let closeY: CGFloat
                if let baseline {
                    closeY = size.height * (1 - CGFloat((baseline - lower) / span))
                } else {
                    closeY = size.height
                }
                var area = line
                area.addLine(to: CGPoint(x: size.width, y: closeY))
                area.addLine(to: CGPoint(x: 0, y: closeY))
                area.closeSubpath()
                context.fill(area, with: .linearGradient(
                    Gradient(colors: [color.opacity(0.26), color.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: Swift.min(closeY, line.boundingRect.minY)),
                    endPoint: CGPoint(x: 0, y: closeY)))
            }

            context.stroke(line, with: .color(color),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
        .drawingGroup(opaque: false)
    }
}

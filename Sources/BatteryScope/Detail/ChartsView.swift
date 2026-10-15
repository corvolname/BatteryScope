import SwiftUI
import Charts
import BatteryKit

/// Full-size charts. Each selected metric gets its own plot because the metrics have
/// incompatible units — plotting watts and percent on one axis would be a lie.
struct ChartsView: View {

    @ObservedObject var monitor: BatteryMonitor

    // Three distinct live signals.
    //
    // 电量 was the obvious first choice and the wrong one: measured over 40 s it does not move at
    // all (97 % → 97 %), so the default chart was a flat line with an axis around it — the "these
    // charts make no sense" complaint in one picture.
    //
    // 电池功率 is left out of the default even though it is live, because on battery it is exactly
    // −整机功耗 (the firmware derives one from the other), so showing both spends a third of the
    // window restating one number. The three below are independent.
    @State private var selected: Set<SampleMetric> = [.systemLoad, .cpuLoad, .gpuLoad]
    @State private var range: ChartRange = .fifteenMinutes

    private var orderedSelection: [SampleMetric] {
        SampleMetric.allCases.filter { selected.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            if monitor.samples.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(orderedSelection) { metric in
                            MetricChart(metric: metric, points: points(for: metric))
                        }
                        if orderedSelection.isEmpty {
                            Text("上面点一个指标，这里就会画出它的变化。")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 30)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    // MARK: - Controls

    /// Two rows on purpose.
    ///
    /// Everything used to share one `HStack`: ten chips, then a 330 pt range picker, then the sample
    /// count. That is more than the window is wide, so the chips were compressed until their labels
    /// truncated and the picker's last segment ended up against the count. The chips now wrap onto
    /// as many lines as they need, and the range controls get their own row.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Two groups, live readings first.
            //
            // All ten chips used to sit in one run, which put 电量 and 健康度 — neither of which
            // moves within a session — on equal footing with 电池功率 and CPU 温度, which change
            // every second. They are still selectable (over 本次会话, 电量 is a real discharge
            // curve), just not presented as live readings.
            VStack(alignment: .leading, spacing: 6) {
                ForEach(MetricCategory.allCases) { category in
                    HStack(alignment: .top, spacing: 6) {
                        Text(category.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(category == .trend ? .tertiary : .secondary)
                            .frame(width: 26, alignment: .leading)
                            .padding(.top, 2)
                        chips(for: SampleMetric.cases(in: category))
                    }
                }
            }

            HStack(alignment: .center, spacing: 10) {
                Picker("范围", selection: $range) {
                    ForEach(ChartRange.offered) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                // No fixed width. A hard 330 pt fitted the pre-Tahoe segmented control, but the
                // current one is a capsule with wider segments: at 330 pt it overflowed its frame
                // and drew over the text beside it ("30 天归档采样点").
                .fixedSize()

                // The sample count is gone: how many readings the app happens to hold says nothing
                // to the reader. The range picker already says which window they are looking at.
                Spacer(minLength: 0)
            }
        }
    }

    private func chips(for metrics: [SampleMetric]) -> some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(metrics) { metric in
                Toggle(isOn: Binding(
                    get: { selected.contains(metric) },
                    set: { isOn in
                        if isOn { selected.insert(metric) } else { selected.remove(metric) }
                    }
                )) {
                    Text(metric.displayName)
                        .font(.system(size: 11))
                        .fixedSize()
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .tint(Theme.metricColor(metric))
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("正在采集数据…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private func cutoff() -> Date? {
        guard let duration = range.duration else { return nil }
        return Date().addingTimeInterval(-duration)
    }

    private func points(for metric: SampleMetric) -> [ChartPoint] {
        guard let cutoff = cutoff() else { return monitor.series(metric, since: nil, limit: 700) }
        if let oldestLive = monitor.samples.first?.timestamp, cutoff >= oldestLive {
            return monitor.series(metric, since: cutoff, limit: 700)
        }
        // 归档是每分钟一条：30 天约 43,200 条，交给 downsampler 压到 700 点。
        return monitor.history.series(metric, from: .archive, since: cutoff, limit: 700)
    }

    /// 本次会话直接用内存缓冲；超出内存保留期的范围走归档。
    ///
    /// 判据是"截止时刻是否早于内存里最老的一条"，不是把 6 小时写死在范围枚举里——两处保留期常量
    /// 若将来调整，这里自动跟随。
    private var sourceSamples: [BatterySample] {
        guard let cutoff = cutoff() else { return monitor.samples }
        if let oldestLive = monitor.samples.first?.timestamp, cutoff >= oldestLive {
            return monitor.samples.filter { $0.timestamp >= cutoff }
        }
        return monitor.history.archive.filter { $0.timestamp >= cutoff }
    }

}

// MARK: - Single metric chart

struct MetricChart: View {
    let metric: SampleMetric
    let points: [ChartPoint]
    var height: CGFloat = 150

    private var color: Color { Theme.metricColor(metric) }

    /// True when the series does not move enough to be worth a scale.
    ///
    /// A battery sitting at 100 % for the whole window produced a plot with a 99.5–100 axis and a
    /// line pinned to the top edge — an axis and a grid saying nothing, which is most of what made
    /// this tab look harder than it is.
    private var isFlat: Bool {
        guard let low = points.map(\.value).min(), let high = points.map(\.value).max() else { return true }
        return (high - low) < metric.minimumSpan
    }

    /// "一直是 100.0%" or "最低 19.1 W · 最高 28.4 W" — what the line did, in words.
    ///
    /// This replaces "区间 100.0% → 100.0%", which restated the two axis ends and said nothing
    /// about the shape in between.
    private var summary: String {
        guard let low = points.map(\.value).min(), let high = points.map(\.value).max() else { return "" }
        if isFlat { return "一直是 \(format(high))" }
        return "最低 \(format(low)) · 最高 \(format(high))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(metric.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(summary)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                if let last = points.last {
                    Text(format(last.value))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(color)
                        .monospacedDigit()
                }
            }

            if points.count >= 2 {
                Chart {
                    ForEach(points) { point in
                        AreaMark(x: .value("时间", point.date),
                                 y: .value(metric.displayName, point.value))
                            .foregroundStyle(LinearGradient(
                                colors: [color.opacity(0.17), color.opacity(0.01)],
                                startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)

                        LineMark(x: .value("时间", point.date),
                                 y: .value(metric.displayName, point.value))
                            .foregroundStyle(color)
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                    }
                    if metric.isSigned {
                        RuleMark(y: .value("零线", 0))
                            .foregroundStyle(Color.secondary.opacity(0.45))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    }
                }
                .chartYScale(domain: yDomain)
                // Two labels, at the ends, and no grid at all.
                //
                // Each chart used to carry five dashed vertical grid lines, a tick and a time label
                // under every one of them, four dashed horizontal grid lines and a scale down the
                // right side — about twenty marks per chart, doubled for two charts. With the time
                // span already named by the range picker ("最近 5 分钟") almost none of that was
                // telling the reader anything the shape of the line did not.
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisValueLabel(format: axisLabelFormat)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }
                .chartYAxis {
                    // No scale when the line is flat: a scale around a straight line is decoration.
                    if !isFlat {
                        AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                            AxisValueLabel {
                                if let double = value.as(Double.self) {
                                    Text(shortFormat(double))
                                        .font(.system(size: 9))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
                .frame(height: height)
                // The area fill escapes the plot: with the chart bounded to 150 pt the gradient was
                // still painted a few hundred points further down, leaving a large wash of the
                // series colour under the chart. Clipping keeps the drawing inside its own frame.
                .clipped()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04))
                    Text("该范围内数据不足（需要至少 2 个采样点）")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(height: height)
            }
        }
    }

    /// Picks a time format that actually distinguishes the ticks across the plotted window.
    private var axisLabelFormat: Date.FormatStyle {
        guard let first = points.first?.date, let last = points.last?.date else {
            return .dateTime.hour().minute()
        }
        let span = last.timeIntervalSince(first)
        if span < 600 { return .dateTime.minute().second() }
        if span > 2 * 86_400 { return .dateTime.month(.abbreviated).day() }
        return .dateTime.hour().minute()
    }

    private var yDomain: ClosedRange<Double> {
        let values = points.map(\.value)
        guard var lower = values.min(), var upper = values.max() else { return 0...1 }
        if metric.isSigned {
            lower = Swift.min(lower, 0)
            upper = Swift.max(upper, 0)
        }
        // Enforce the metric's minimum span so noise is not stretched to full scale.
        let midpoint = (lower + upper) / 2
        if upper - lower < metric.minimumSpan {
            lower = midpoint - metric.minimumSpan / 2
            upper = midpoint + metric.minimumSpan / 2
            if metric.isSigned {
                lower = Swift.min(lower, 0)
                upper = Swift.max(upper, 0)
            }
        }
        if upper - lower < 0.0001 {
            upper += 1
            lower -= 1
        }
        let padding = (upper - lower) * 0.12
        return (lower - padding)...(upper + padding)
    }

    private func shortFormat(_ value: Double) -> String {
        let magnitude = abs(value)
        if magnitude >= 1000 { return String(format: "%.0f", value) }
        if magnitude >= 100 { return String(format: "%.0f", value) }
        if magnitude >= 10 { return String(format: "%.1f", value) }
        return String(format: "%.2f", value)
    }

    private func format(_ value: Double) -> String {
        switch metric {
        case .chargePercent, .healthPercent: return String(format: "%.1f%%", value)
        case .power: return String(format: "%+.2f W", value)
        case .systemLoad, .adapterPower: return String(format: "%.2f W", value)
        case .cpuTemperature, .gpuTemperature, .temperature: return String(format: "%.1f °C", value)
        case .capacity: return String(format: "%.0f mAh", value)
        case .voltage: return String(format: "%.3f V", value)
        case .cpuLoad, .gpuLoad, .memory: return String(format: "%.0f%%", value)
        case .fanRPM: return String(format: "%.0f rpm", value)
        case .batteryCurrent: return String(format: "%+.2f A", value)
        }
    }
}

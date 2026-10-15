import SwiftUI
import BatteryKit

/// The card that drops down from the menu bar icon.
///
/// Design rules, deliberately followed throughout:
///
/// * **Real-time only.** Every value here is a direct reading. Nothing is a computed "nominal"
///   figure presented as if it were a measurement.
/// * **No provenance clutter.** Values are plain numbers. The card is not the place to explain
///   which register a watt came from.
/// * **macOS conventions.** System text styles, semantic colours, label/value rows and a single
///   neutral capacity bar — no saturated tiles.
/// * **Nothing else.** No advisories and no per-section buttons. The only control is the settings
///   gear; the richer views live in the menu bar icon's context menu.
struct CardView: View {

    @ObservedObject var monitor: BatteryMonitor
    let actions: CardActions

    private var snapshot: BatterySnapshot? { monitor.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if monitor.isAvailable {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    Divider()
                    powerCharts
                    if snapshot?.thermal != nil {
                        Divider()
                        liveSensorGroup
                    }
                    Divider()
                    batteryGroup
                }
                .padding(14)
            } else {
                noBattery
            }
            Divider()
            footer
        }
        .frame(width: 320)
        // No background here on purpose.
        //
        // `NSPopover` already draws the standard popover material behind its content view. Stacking
        // a SwiftUI `.regularMaterial` on top of it compounded the two, and the result read as a
        // flat grey card instead of the translucent panel macOS — and every other menu-bar popover —
        // shows. Leaving the hosting view transparent lets the popover's own material through.
    }

    // MARK: - No battery

    private var noBattery: some View {
        VStack(spacing: 6) {
            Image(systemName: "powerplug")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
            Text("此 Mac 没有内置电池")
                .font(.headline)
            Text("接入带电池的设备或 UPS 后会自动开始显示。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(28)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(percentText)
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(accentColor)

                if snapshot?.isCharging == true {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                }

                Spacer(minLength: 6)

                Text(snapshot?.powerSourceDescription ?? "正在读取…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            CapacityBar(fraction: (snapshot?.chargePercent ?? 0) / 100,
                        color: accentColor,
                        isPulsing: snapshot?.isCharging == true)

            if let detail = statusDetailText {
                HStack(spacing: 4) {
                    Image(systemName: "clock").font(.system(size: 9))
                    Text(detail).font(.caption).monospacedDigit()
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    /// While charging the useful number is time-to-full; while on battery it is time-to-empty.
    /// The hardware's own estimate is preferred where it exists, otherwise the measured slope
    /// from the sample history is used.
    private var statusDetailText: String? {
        guard let snapshot else { return nil }
        if snapshot.isCharging {
            guard let minutes = monitor.bestTimeToFullMinutes else { return "正在估算充满时间…" }
            return "预计 \(UnitFormat.minutes(minutes))后充满"
        }
        if !snapshot.externalConnected {
            guard let minutes = monitor.bestTimeToEmptyMinutes else { return "正在估算可用时间…" }
            return "预计可用 \(UnitFormat.minutes(minutes))"
        }
        return snapshot.fullyCharged ? "已充满" : nil
    }

    private var percentText: String {
        guard let percent = snapshot?.chargePercent else { return "—" }
        return String(format: "%.0f%%", percent)
    }

    /// Neutral by default so the card reads like a system pane; colour is reserved for the two
    /// states worth noticing at a glance.
    private var accentColor: Color {
        stateColor(neutral: .primary)
    }

    private func stateColor(neutral: Color) -> Color {
        guard let snapshot else { return neutral }
        if let percent = snapshot.chargePercent {
            if percent <= 10 { return .red }
            if percent <= 20 { return .yellow }
        }
        // Green whenever a charger is attached, not only while current is flowing.
        //
        // Gating on `isCharging` meant that the common "plugged in and full" state — macOS reports
        // isCharging = false there — fell through to `neutral`, which painted the capacity bar
        // solid black. The menu bar icon already uses the charger-attached rule, so this also makes
        // the two surfaces agree.
        if snapshot.externalConnected { return .green }
        return neutral
    }

    // MARK: - Groups

    /// The power flows, each with its live trend. Current values live in the chart captions
    /// rather than in separate rows, so no number is printed twice.
    ///
    /// Two charts are conditional, because a flat line at zero is noise rather than information:
    ///
    /// * **电池功率** appears only while the battery is actually moving charge. On AC with a
    ///   full or paused battery it is a constant 0 W, so it is hidden instead.
    /// * **适配器供电** appears only while an adapter is attached.
    ///
    /// 整机功耗 is always meaningful — the machine is always drawing something.
    private var powerCharts: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupTitle(snapshot?.hasLivePowerSource == true ? "供电 · 实测（秒级）" : "供电")

            if showsBatteryPowerChart {
                MiniChart(title: "电池功率",
                          points: chartPoints(.power),
                          color: Theme.metricColor(.power),
                          valueText: batteryPowerText,
                          minimumSpan: SampleMetric.power.minimumSpan,
                          baseline: nil)
            }

            MiniChart(title: "整机功耗",
                      points: chartPoints(.systemLoad),
                      color: Theme.metricColor(.systemLoad),
                      valueText: wattsText(snapshot?.liveSystemLoadWatts),
                      minimumSpan: SampleMetric.systemLoad.minimumSpan,
                      baseline: nil)

            if isOnExternalPower {
                MiniChart(title: "适配器供电",
                          points: chartPoints(.adapterPower),
                          color: Theme.metricColor(.adapterPower),
                          valueText: adapterSupplyText,
                          minimumSpan: SampleMetric.adapterPower.minimumSpan,
                          baseline: nil)
            }
        }
    }

    /// CPU and GPU die temperatures.
    ///
    /// The battery node cannot provide these at all, so they get their own group rather than being
    /// mixed into the 电池 block. They come from the SMC's `Tp`/`Te` (cores) and `Tg` (graphics)
    /// sensors — see `SMCThermalReader` for why the faster PMU HID channels were not usable for
    /// splitting CPU from GPU.
    private var liveSensorGroup: some View {
        VStack(alignment: .leading, spacing: 10) {
            groupTitle("实时传感器（秒级）")
            MiniChart(title: "CPU 温度",
                      points: chartPoints(.cpuTemperature),
                      color: Theme.metricColor(.cpuTemperature),
                      valueText: UnitFormat.celsius(snapshot?.cpuTemperatureCelsius),
                      minimumSpan: SampleMetric.cpuTemperature.minimumSpan,
                      baseline: nil,
                      emptyText: "SMC 不可用")
            MiniChart(title: "GPU 温度",
                      points: chartPoints(.gpuTemperature),
                      color: Theme.metricColor(.gpuTemperature),
                      valueText: UnitFormat.celsius(snapshot?.gpuTemperatureCelsius),
                      minimumSpan: SampleMetric.gpuTemperature.minimumSpan,
                      baseline: nil,
                      emptyText: "SMC 不可用")
        }
    }

    private var showsBatteryPowerChart: Bool {
        snapshot?.isBatteryActivelyMovingCharge == true
    }

    /// Chart data for one metric.
    ///
    /// This used to be `monitor.series(metric, since: Date().addingTimeInterval(-600))` called four
    /// times inside `body`: the window start moved on every render, so nothing could be cached, and
    /// each call filtered + mapped + downsampled the entire sample buffer. `chartSeries` memoises the
    /// result until the next batch of samples arrives.
    private func chartPoints(_ metric: SampleMetric) -> [ChartPoint] {
        monitor.chartSeries(metric)
    }

    private var isOnExternalPower: Bool { snapshot?.externalConnected == true }

    /// Related values are grouped onto one entry as main label + sub-text instead of one row
    /// each: health and cycle count describe the same thing (aging), and the three capacities
    /// are the same quantity at three points in the pack's life.
    private var batteryGroup: some View {
        VStack(alignment: .leading, spacing: 9) {
            groupTitle("电池")

            MetricRow(label: "健康度",
                      sublabel: "循环次数 \(cycleText)",
                      value: UnitFormat.percent(snapshot?.healthPercent, fractionDigits: 1))

            MetricRow(label: "温度",
                      value: UnitFormat.celsius(snapshot?.temperatureCelsius))

            MetricRow(label: "当前容量",
                      sublabel: capacityReferenceText,
                      value: UnitFormat.milliampHours(snapshot?.currentCapacityMAh))

            MetricRow(label: "电压 / 电流",
                      value: "\(voltsText) · \(ampsText)")
        }
    }

    /// 满充容量与设计容量都是参考值，放在当前容量下面作为小字。
    private var capacityReferenceText: String? {
        guard let snapshot else { return nil }
        var parts: [String] = []
        if let max = snapshot.maxCapacityMAh { parts.append("满充 \(UnitFormat.grouped(max))") }
        if let design = snapshot.designCapacityMAh { parts.append("设计 \(UnitFormat.grouped(design))") }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ") + " mAh"
    }

    private func groupTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    // MARK: - Value formatting

    private var batteryPowerText: String {
        guard let power = snapshot?.liveBatteryPowerWatts else { return "—" }
        if abs(power) < 0.05 { return "0 W" }
        return UnitFormat.signedWatts(power)
    }

    private func wattsText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return UnitFormat.watts(value)
    }

    private var adapterSupplyText: String {
        guard isOnExternalPower else { return "未连接" }
        return wattsText(snapshot?.liveAdapterInputWatts)
    }

    private var cycleText: String {
        guard let cycles = snapshot?.cycleCount else { return "—" }
        guard let design = snapshot?.designCycleCount else { return "\(cycles)" }
        return "\(cycles) / \(design)"
    }

    private var voltsText: String {
        guard let volts = snapshot?.voltageVolts else { return "—" }
        return String(format: "%.2f V", volts)
    }

    private var ampsText: String {
        guard let amps = snapshot?.amperageAmps else { return "—" }
        if abs(amps) < 0.0005 { return "0 mA" }
        return String(format: "%.2f A", amps)
    }

    // MARK: - Footer

    /// No data-age readout here on purpose. It only explained why the numbers looked stale
    /// without making them any fresher; the reason is documented in the README instead.
    private var footer: some View {
        HStack {
            Spacer()
            Button {
                actions.openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .help("偏好设置")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }


    private func ageText(_ age: TimeInterval) -> String {
        if age < 2 { return "刚刚" }
        if age < 60 { return "\(Int(age)) 秒前" }
        let minutes = Int(age) / 60
        let seconds = Int(age) % 60
        return seconds == 0 ? "\(minutes) 分钟前" : "\(minutes) 分 \(seconds) 秒前"
    }
}

// MARK: - Building blocks

/// One label/value row, laid out the way macOS system panes do it.
private struct MetricRow: View {
    let label: String
    var sublabel: String?
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let sublabel {
                    Text(sublabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 8)
            Text(value)
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(valueColor)
        }
    }
}

/// A compact trend line with its current value. Deliberately plain: a line and a number, with no
/// gradient fill or coloured frame.
private struct MiniChart: View {
    let title: String
    let points: [ChartPoint]
    let color: Color
    let valueText: String
    let minimumSpan: Double
    let baseline: Double?
    /// Replaces the "collecting…" placeholder when there is nothing that could ever be plotted
    /// (for example the adapter supply while running on battery).
    var emptyText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(valueText)
                    .font(.callout)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
            if points.count >= 2 {
                Sparkline(points: points,
                          color: color,
                          baseline: baseline,
                          lineWidth: 1.2,
                          showsArea: true,
                          minimumSpan: minimumSpan)
                    .frame(height: 28)
            } else {
                RoundedRectangle(cornerRadius: Theme.corner - Theme.cardPadding)
                    .fill(Color.primary.opacity(0.05))
                    .frame(height: 28)
                    .overlay(
                        Text(emptyText ?? "采集中…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    )
            }
        }
    }
}

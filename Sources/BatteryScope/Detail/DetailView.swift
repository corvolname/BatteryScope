import SwiftUI
import BatteryKit

struct DetailView: View {

    @ObservedObject var monitor: BatteryMonitor
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TabView(selection: $appState.selectedTab) {
                OverviewView(monitor: monitor)
                    .tabItem { Label(DetailTab.overview.title, systemImage: DetailTab.overview.symbol) }
                    .tag(DetailTab.overview)

                ChartsView(monitor: monitor)
                    .tabItem { Label(DetailTab.charts.title, systemImage: DetailTab.charts.symbol) }
                    .tag(DetailTab.charts)

                RawKeysView(monitor: monitor)
                    .tabItem { Label(DetailTab.rawKeys.title, systemImage: DetailTab.rawKeys.symbol) }
                    .tag(DetailTab.rawKeys)
            }
            // Top padding as well as the sides and bottom.
            //
            // Without it the tab content started hard against the divider under the header: the
            // 原始键值 search field sat flush on that edge, and the 实时图表 filter row did too.
            // Already-present inner padding (4 pt on the overview scroll view, 10 pt in the charts
            // stack) was there to separate content from itself, not from the header.
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 16)
        }
        .frame(minWidth: 860, minHeight: 540)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ChargeRing(percent: monitor.snapshot?.chargePercent,
                       color: Theme.statusColor(monitor.snapshot),
                       size: 58,
                       lineWidth: 7)

            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.snapshot?.powerSourceDescription ?? "正在读取电池信息…")
                    .font(.system(size: 15, weight: .semibold))
                Text("\(monitor.profile.modelMarketingName) · \(monitor.profile.chipName) · \(monitor.profile.memoryDescription) · \(monitor.profile.osDescription)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 3) {
                if let last = monitor.lastReadAt {
                    Text("最后读取 \(UnitFormat.timeOnly(last))")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(Theme.charging)
                        .frame(width: 6, height: 6)
                    Text("实时采样中（\(String(format: "%.0f", monitor.samplingInterval))s）")
                        .foregroundStyle(.secondary)
                    Text("· 读取耗时 \(String(format: "%.1f", monitor.lastReadDuration * 1000))ms")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

// MARK: - Overview

struct OverviewView: View {

    @ObservedObject var monitor: BatteryMonitor

    private var snapshot: BatterySnapshot? { monitor.snapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if monitor.isAvailable {
                    headline

                    if let advisories = snapshot?.advisories, !advisories.isEmpty {
                        SectionCard(title: "提示", systemImage: "exclamationmark.triangle", accent: Theme.advisory) {
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(advisories.enumerated()), id: \.offset) { _, advisory in
                                    Text("• \(advisory)")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    // Cards hug their contents.
                    //
                    // They used to be stretched to the height of the tallest card in their row,
                    // which is what produced the empty space the 电气 / 系统功耗 / 电芯组 cards were
                    // showing. Merging those three removed the worst of it but only moved the rest
                    // to their new neighbour (容量 ended up four rows short of 电气与功耗), so the
                    // stretching itself is gone: a row's cards now end where their content ends.
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)],
                              alignment: .leading, spacing: 18) {
                        ForEach(sections, id: \.title) { section in
                            SectionCard(title: section.title) {
                                VStack(spacing: 7) {
                                    ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                                        KeyValueRow(label: row.label, value: row.value, note: row.note, singleLine: true)
                                    }
                                }
                            }
                        }
                    }
                } else {
                    Text("此 Mac 没有内置电池。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 40)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// "4 小时 30 分" / "30 分钟" — the menu bar's compact form is too terse for a window.
    private static func durationText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let mins = minutes % 60
        if hours > 0 && mins > 0 { return "\(hours) 小时 \(mins) 分" }
        if hours > 0 { return "\(hours) 小时" }
        return "\(mins) 分钟"
    }

    /// "真实容量 7,779 mAh / 设计容量 8,694 mAh", with the measured half omitted when unavailable.
    /// The design capacity, under the rings.
    ///
    /// The measured capacity is a row in the readings column instead, so repeating both here said
    /// the same thing twice.
    private func capacityCaption(design: Int) -> String {
        "设计容量 \(UnitFormat.grouped(design)) mAh"
    }

    private var sections: [ReportSection] {
        snapshot?.detailSections() ?? []
    }

    private var headline: some View {
        SectionCard(title: "总览", systemImage: "gauge.with.dots.needle.50percent", accent: Theme.charging) {
            // Two zones, split by a divider: the graphics on the left, the readings on the right.
            //
            // They used to share one nested stack, which put the health bar (maxWidth 420, laid out
            // from the leading edge of the *inner* stack) underneath both — it began under the rings
            // and ran on under the text columns, cutting straight across the boundary between the
            // two groups. Constraining the bar to the width of the rings keeps every graphic in the
            // graphics zone, and the divider makes the split legible rather than implied.
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 12) {
                    // No charge-level ring here: the window's header already shows one, with the
                    // same percentage and the same status caption, a few centimetres above. Two
                    // identical rings on one screen is duplication, not emphasis.
                    HStack(spacing: 20) {
                        SmallRing(title: "健康度",
                                  percent: snapshot?.healthPercent,
                                  color: Theme.healthColor(snapshot?.healthPercent),
                                  size: 84, lineWidth: 9)
                        SmallRing(title: "循环次数占用",
                                  percent: snapshot?.cycleUsagePercent,
                                  color: Theme.seriesCapacity,
                                  size: 84, lineWidth: 9,
                                  centerText: snapshot?.cycleCount.map { "\($0)" } ?? "—",
                                  caption: snapshot?.designCycleCount.map { "上限 \($0)" })
                    }
                    // Centred in the column so the rings' axis matches the caption's below them.
                    .frame(maxWidth: .infinity)

                    if let health = snapshot?.healthPercent,
                       let design = snapshot?.designCapacityMAh {
                        VStack(alignment: .center, spacing: 4) {
                            // Both numbers behind the ratio, rather than the design capacity alone:
                            // the ring above shows the percentage, and this line says which two
                            // measurements produced it.
                            Text(capacityCaption(design: design))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                            CapacityBar(fraction: health / 100, color: Theme.healthColor(health), height: 6)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .frame(width: Self.ringZoneWidth, alignment: .leading)

                Divider()

                HStack(alignment: .top, spacing: 40) {
                    // Left: condition and everything thermal. The fan belongs here rather than with
                    // the hardware identity it used to sit beside.
                    //
                    // Five rows whatever the state, with `—` for anything missing. A fanless Mac, or
                    // one whose SMC exposes no die sensors, gets a dashed row rather than a shorter
                    // column — the two columns must stay level or the card stops reading as a grid.
                    VStack(alignment: .leading, spacing: 8) {
                        KeyValueRow(label: "电池状况", value: snapshot?.condition.displayName ?? "—", singleLine: true)
                        KeyValueRow(label: "电池温度", value: UnitFormat.celsius(snapshot?.temperatureCelsius), singleLine: true)
                        KeyValueRow(label: "CPU 温度", value: UnitFormat.celsius(snapshot?.cpuTemperatureCelsius), singleLine: true)
                        KeyValueRow(label: "GPU 温度", value: UnitFormat.celsius(snapshot?.gpuTemperatureCelsius), singleLine: true)
                        KeyValueRow(label: "风扇转速",
                                    value: snapshot?.fanRPM.map { String(format: "%.0f rpm", $0) } ?? "—",
                                    singleLine: true)
                    }
                    .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)

                    // Right: five rows, matching the five on the left, so the two columns' rows line
                    // up with each other and the card reads as a grid.
                    //
                    // 电池序列号 is deliberately absent — it is in the 标识 card, and showing one
                    // value in two cards is the duplication this row used to be. 电量计芯片 is the
                    // mirror case: it lives here (it is the source of every capacity reading) and is
                    // dropped from 标识.
                    VStack(alignment: .leading, spacing: 8) {
                        KeyValueRow(label: "电量计芯片", value: snapshot?.deviceName ?? "—", singleLine: true)
                        KeyValueRow(label: "当前剩余容量",
                                    value: snapshot?.currentCapacityMAh.map { "\(UnitFormat.grouped($0)) mAh" } ?? "—",
                                    singleLine: true)
                        KeyValueRow(label: "相对设计容量的衰减",
                                    value: snapshot?.capacityFadeMAh.map { "\(UnitFormat.grouped($0)) mAh" } ?? "—",
                                    singleLine: true)
                        // The measured full-charge capacity as a row of its own. It used to be
                        // 标称满充容量（模型值）— the gauge's *modelled* capacity, which is what
                        // macOS reports as battery health (92 % here) and what comparable apps show.
                        // That number is not a measurement, so it is gone: the health ring, the
                        // caption and this row all use AppleRawMaxCapacity, the capacity the pack
                        // actually reached (89.5 %).
                        KeyValueRow(label: "真实容量（实测满充）",
                                    value: snapshot?.maxCapacityMAh.map { "\(UnitFormat.grouped($0)) mAh" } ?? "—",
                                    singleLine: true)
                        // Always occupies a row, showing "—" when the estimate is unavailable:
                        // dropping it in some states would shift this column's rows out of line
                        // with the other column's, which is the whole point of the fixed count.
                        let onAC = snapshot?.externalConnected == true
                        KeyValueRow(label: onAC ? "预计充满时间" : "预计续航时间",
                                    value: (onAC ? monitor.timeToFullMinutes : monitor.timeToEmptyMinutes)
                                        .map(Self.durationText) ?? "—",
                                    singleLine: true)
                    }
                    .frame(minWidth: 170, maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// Width of the graphics column: wide enough for the capacity caption on one line, narrow enough
    /// to leave the readings columns room. The rings are centred in it so their axis matches the
    /// caption's — with a leading-aligned column and a centred caption the two disagreed.
    private static let ringZoneWidth: CGFloat = 250
}

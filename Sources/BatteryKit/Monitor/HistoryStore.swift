import Foundation

/// One point on the timeline. Kept deliberately small and `Codable` so the same type serves
/// the live charts, the on-disk history and anything exported later.
public struct BatterySample: Codable, Identifiable, Hashable {
    public var timestamp: Date
    public var chargePercent: Double?
    public var currentCapacityMAh: Double?
    public var maxCapacityMAh: Double?
    public var voltage: Double?
    public var amperage: Double?
    public var batteryPowerWatts: Double?
    public var systemLoadWatts: Double?
    public var adapterInputWatts: Double?
    public var temperature: Double?
    public var healthPercent: Double?
    /// Hottest PMU sensor reading; the only sample field that is genuinely sub-second.
    public var cpuTemperature: Double?
    public var gpuTemperature: Double?
    /// Live load figures, all sampled every tick.
    public var cpuLoadPercent: Double?
    public var gpuLoadPercent: Double?
    public var memoryUsedPercent: Double?
    public var fanRPM: Double?
    public var batteryCurrentAmps: Double?
    public var cycleCount: Int?
    public var isCharging: Bool
    public var externalConnected: Bool

    public var id: Date { timestamp }

    public init(timestamp: Date,
                chargePercent: Double? = nil,
                currentCapacityMAh: Double? = nil,
                maxCapacityMAh: Double? = nil,
                voltage: Double? = nil,
                amperage: Double? = nil,
                batteryPowerWatts: Double? = nil,
                systemLoadWatts: Double? = nil,
                adapterInputWatts: Double? = nil,
                temperature: Double? = nil,
                healthPercent: Double? = nil,
                cpuTemperature: Double? = nil,
                gpuTemperature: Double? = nil,
                cpuLoadPercent: Double? = nil,
                gpuLoadPercent: Double? = nil,
                memoryUsedPercent: Double? = nil,
                fanRPM: Double? = nil,
                batteryCurrentAmps: Double? = nil,
                cycleCount: Int? = nil,
                isCharging: Bool = false,
                externalConnected: Bool = false) {
        self.timestamp = timestamp
        self.chargePercent = chargePercent
        self.currentCapacityMAh = currentCapacityMAh
        self.maxCapacityMAh = maxCapacityMAh
        self.voltage = voltage
        self.amperage = amperage
        self.batteryPowerWatts = batteryPowerWatts
        self.systemLoadWatts = systemLoadWatts
        self.adapterInputWatts = adapterInputWatts
        self.temperature = temperature
        self.healthPercent = healthPercent
        self.cpuTemperature = cpuTemperature
        self.gpuTemperature = gpuTemperature
        self.cpuLoadPercent = cpuLoadPercent
        self.gpuLoadPercent = gpuLoadPercent
        self.memoryUsedPercent = memoryUsedPercent
        self.fanRPM = fanRPM
        self.batteryCurrentAmps = batteryCurrentAmps
        self.cycleCount = cycleCount
        self.isCharging = isCharging
        self.externalConnected = externalConnected
    }

    public init(timestamp: Date, snapshot: BatterySnapshot,
                powerSource: BatterySnapshot.BatteryPowerSource = .automatic) {
        self.timestamp = timestamp
        self.chargePercent = snapshot.chargePercent
        self.currentCapacityMAh = snapshot.currentCapacityMAh.map(Double.init)
        self.maxCapacityMAh = snapshot.maxCapacityMAh.map(Double.init)
        self.voltage = snapshot.voltageVolts
        self.amperage = snapshot.amperageAmps
        // Prefer the ~1 Hz SMC readings so the charts move every second instead of once a minute.
        self.batteryPowerWatts = snapshot.liveBatteryPowerWatts
                                  ?? snapshot.batteryPower(using: powerSource)?.watts
        self.systemLoadWatts = snapshot.liveSystemLoadWatts
        self.adapterInputWatts = snapshot.liveAdapterInputWatts
        self.temperature = snapshot.temperatureCelsius
        self.healthPercent = snapshot.healthPercent
        self.cpuTemperature = snapshot.cpuTemperatureCelsius
        self.gpuTemperature = snapshot.gpuTemperatureCelsius
        self.cpuLoadPercent = snapshot.systemLoad?.cpuLoadPercent
        self.gpuLoadPercent = snapshot.systemLoad?.gpuLoadPercent
        self.memoryUsedPercent = snapshot.systemLoad?.memoryUsedPercent
        self.fanRPM = snapshot.smcPower?.fanRPM
        self.batteryCurrentAmps = snapshot.smcPower?.batteryCurrentAmps
        self.cycleCount = snapshot.cycleCount
        self.isCharging = snapshot.isCharging
        self.externalConnected = snapshot.externalConnected
    }
}

/// A single plotted point. Separate from `BatterySample` so charts never have to deal with
/// optional values or pick which field they are drawing.
public struct ChartPoint: Identifiable, Hashable {
    public let id: Int
    public let date: Date
    public let value: Double

    public init(id: Int, date: Date, value: Double) {
        self.id = id
        self.date = date
        self.value = value
    }
}

/// The fields that can be plotted, so menus and legends stay in sync with the charts.
public enum SampleMetric: String, CaseIterable, Identifiable {
    case chargePercent
    /// Battery power: positive while charging, negative while discharging.
    case power
    /// Total power the machine is consuming.
    case systemLoad
    /// Power the adapter is actually delivering right now.
    case adapterPower
    /// Hottest PMU sensor. The only metric here that updates at sub-second rate.
    case cpuTemperature
    case gpuTemperature
    case temperature
    case capacity
    case voltage
    case healthPercent
    /// Live load readings — all move every second, which is the whole point of the tab.
    case cpuLoad
    case gpuLoad
    case memory
    case fanRPM
    case batteryCurrent

    public var id: String { rawValue }

    /// Whether this metric actually moves on the timescale the live tab shows.
    ///
    /// Measured by sampling for 40 s and comparing each reading's movement against its own chart
    /// span — a metric that traverses none of its range has no shape to draw there:
    ///
    /// | metric | movement in 40 s | share of its span |
    /// |---|---|---|
    /// | 电量 | 97 % → 97 % | 0 % |
    /// | 电池温度 | 32.9 → 33.1 °C | negligible |
    /// | 容量 / 健康度 | none (those move over days) | 0 % |
    /// | 电池功率 | −20.6 → −26.5 W | ±15 % |
    /// | 整机功耗 | 20.9 → 26.9 W | ±15 % |
    /// | 电池电压 | 12.453 → 12.242 V | ~70 % of a 0.3 V span |
    ///
    /// 电压 is the one that looks slow and is not: when the load rose from 21 W to 27 W the pack
    /// voltage sagged 0.21 V on internal resistance, which is most of its range.
    ///
    /// The slow four are not wrong to show — over 1 小时 or 本次会话, 电量 is a genuine discharge
    /// curve — so they stay available, but grouped apart from the live ones.
    public var isRealtime: Bool {
        switch self {
        case .power, .systemLoad, .adapterPower, .cpuTemperature, .gpuTemperature, .voltage,
             .cpuLoad, .gpuLoad, .memory, .fanRPM, .batteryCurrent:
            return true
        case .chargePercent, .temperature, .capacity, .healthPercent:
            return false
        }
    }

    /// The two groups the picker draws, live readings first.
    public static var realtimeCases: [SampleMetric] { allCases.filter(\.isRealtime) }
    public static var trendCases: [SampleMetric] { allCases.filter { !$0.isRealtime } }

    /// What kind of quantity this is, so the picker can present a dozen metrics without turning
    /// into an undifferentiated row of chips.
    public var category: MetricCategory {
        switch self {
        case .power, .batteryCurrent, .voltage, .systemLoad, .adapterPower:
            return .power
        case .cpuLoad, .gpuLoad, .memory:
            return .load
        case .cpuTemperature, .gpuTemperature, .temperature, .fanRPM:
            return .thermal
        case .chargePercent, .capacity, .healthPercent:
            return .trend
        }
    }

    public static func cases(in category: MetricCategory) -> [SampleMetric] {
        allCases.filter { $0.category == category }
    }

    /// Short names, as the reader expects them.
    ///
    /// These were briefly spelled out ("处理器温度", "电脑耗电") on the theory that the labels were
    /// what made the chart tab confusing. They were not — the reader reads CPU/GPU/PWR without
    /// help, and the longer labels only widened the chip row. The one change kept is 电池温度:
    /// plain "温度" sitting beside "CPU 温度" and "GPU 温度" left no way to tell which was which.
    public var displayName: String {
        switch self {
        case .chargePercent: return "电量"
        case .power: return "电池功率"
        case .systemLoad: return "整机功耗"
        case .adapterPower: return "适配器供电"
        case .cpuTemperature: return "CPU 温度"
        case .gpuTemperature: return "GPU 温度"
        case .temperature: return "电池温度"
        case .capacity: return "容量"
        case .voltage: return "电压"
        case .healthPercent: return "健康度"
        case .cpuLoad: return "CPU 占用"
        case .gpuLoad: return "GPU 占用"
        case .memory: return "内存占用"
        case .fanRPM: return "风扇转速"
        case .batteryCurrent: return "电池电流"
        }
    }

    public var unit: String {
        switch self {
        case .chargePercent, .healthPercent: return "%"
        case .power, .systemLoad, .adapterPower: return "W"
        case .cpuTemperature, .gpuTemperature, .temperature: return "°C"
        case .capacity: return "mAh"
        case .voltage: return "V"
        case .cpuLoad, .gpuLoad, .memory: return "%"
        case .fanRPM: return "rpm"
        case .batteryCurrent: return "A"
        }
    }

    public func value(from sample: BatterySample) -> Double? {
        switch self {
        case .chargePercent: return sample.chargePercent
        case .power: return sample.batteryPowerWatts
        case .systemLoad: return sample.systemLoadWatts
        case .adapterPower: return sample.adapterInputWatts
        case .cpuTemperature: return sample.cpuTemperature
        case .gpuTemperature: return sample.gpuTemperature
        case .temperature: return sample.temperature
        case .capacity: return sample.currentCapacityMAh
        case .voltage: return sample.voltage
        case .healthPercent: return sample.healthPercent
        case .cpuLoad: return sample.cpuLoadPercent
        case .gpuLoad: return sample.gpuLoadPercent
        case .memory: return sample.memoryUsedPercent
        case .fanRPM: return sample.fanRPM
        case .batteryCurrent: return sample.batteryCurrentAmps
        }
    }

    /// Metrics where a zero-crossing is meaningful (charging vs discharging).
    public var isSigned: Bool { self == .power }

    /// True when a zero reading means "nothing connected" rather than "no flow right now".
    public var requiresExternalPower: Bool { self == .adapterPower }

    /// Smallest vertical span a chart should show for this metric.
    ///
    /// Without this, auto-scaling amplifies sensor noise into a dramatic-looking curve: the
    /// battery temperature sitting at 34.0 °C with ±0.2 °C of dither would otherwise be drawn
    /// as a full-height swing, which reads as alarming when nothing is happening.
    /// Floor on the visible vertical span, per metric.
    ///
    /// These were originally sized for the 30–60 s register data, where a step of tens of watts
    /// was normal and anything smaller was quantisation noise. The power and temperature metrics
    /// now come from the SMC and the PMU at roughly 1 Hz, where the *real* variation is far
    /// smaller — measured over 40 s: `PDTR` 28.9–33.7 W, `PSTR` 23.9–27.2 W, `PPBR` 1.61–1.73 W,
    /// PMU die sensors about 1 °C. A 20 W floor therefore squashed those ripples into a quarter
    /// of the chart height and the lines looked flat. The floors below are set just under the
    /// measured variation so the true shape fills the chart, while pure float jitter (well under
    /// 0.01 W) still reads as flat.
    public var minimumSpan: Double {
        switch self {
        case .chargePercent: return 1          // 1 percentage point
        case .healthPercent: return 0.5
        case .power: return 0.15               // PPBR ripples about 0.12 W
        case .systemLoad: return 1.0           // PSTR ripples about 3.3 W
        case .adapterPower: return 1.0         // PDTR ripples about 4.8 W
        case .cpuTemperature, .gpuTemperature: return 1.0   // die sensors move several °C
        case .temperature: return 0.3
        case .capacity: return 20              // 20 mAh
        case .voltage: return 0.02             // 20 mV
        case .cpuLoad, .gpuLoad, .memory: return 5.0   // percentage points
        case .fanRPM: return 50                // rpm
        case .batteryCurrent: return 0.1       // 100 mA
        }
    }
}

/// Groups for the chart picker.
///
/// Twelve live readings in one undifferentiated run of chips is a wall; grouped by what they
/// measure, a reader can ignore everything except the group they came for.
public enum MetricCategory: String, CaseIterable, Identifiable, Sendable {
    case power
    case load
    case thermal
    case trend

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .power: return "供电"
        case .load: return "负载"
        case .thermal: return "温度"
        case .trend: return "趋势"
        }
    }
}

/// Rolling sample buffer plus optional on-disk persistence.
///
/// * The **live** buffer keeps every sample of the current session (ring-buffered) so the
///   popover sparkline and the detail charts stay responsive.
/// * The **archive** keeps one downsampled record per minute on disk, which is what makes a
///   multi-week health trend possible without unbounded memory or file growth.
public final class HistoryStore {

    public private(set) var live: [BatterySample] = []
    public private(set) var archive: [BatterySample] = []

    /// How long the in-memory live buffer is allowed to grow.
    public var liveRetention: TimeInterval = 6 * 3600
    public var liveCapacity = 24_000
    /// The archive keeps one point per minute for this long.
    public var archiveRetention: TimeInterval = 30 * 24 * 3600
    /// When false, nothing is written to disk (the live in-memory buffer still works).
    public var isPersistenceEnabled = true

    public let fileURL: URL?
    private var lastArchiveWrite: Date?
    private let archiveInterval: TimeInterval = 60
    private let ioQueue = DispatchQueue(label: "com.local.batteryscope.history", qos: .utility)

    public init(fileURL: URL? = HistoryStore.defaultFileURL()) {
        self.fileURL = fileURL
        loadArchive()
    }

    public static func defaultFileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let directory = base.appendingPathComponent("BatteryScope", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("history.jsonl")
    }

    // MARK: - Ingest

    public func append(_ sample: BatterySample) {
        live.append(sample)
        trimLive()

        if let last = lastArchiveWrite, sample.timestamp.timeIntervalSince(last) < archiveInterval { return }
        lastArchiveWrite = sample.timestamp
        archive.append(sample)
        persist(sample)
    }

    private func trimLive() {
        if let cutoff = live.last.map({ $0.timestamp.addingTimeInterval(-liveRetention) }) {
            if let firstKept = live.firstIndex(where: { $0.timestamp >= cutoff }), firstKept > 0 {
                live.removeFirst(firstKept)
            }
        }
        if live.count > liveCapacity {
            live.removeFirst(live.count - liveCapacity)
        }
    }

    public func clearLive() {
        live.removeAll()
        lastArchiveWrite = nil
    }

    public func clearArchive() {
        archive.removeAll()
        guard let fileURL else { return }
        ioQueue.async { try? FileManager.default.removeItem(at: fileURL) }
    }

    // MARK: - Series extraction

    /// Points for a metric, downsampled to at most `limit` values so charts stay smooth
    /// even after hours of 1-second sampling.
    public func series(_ metric: SampleMetric,
                       from source: Source = .live,
                       since: Date? = nil,
                       limit: Int = 600) -> [ChartPoint] {
        let samples: [BatterySample] = {
            let base = source == .live ? live : archive
            guard let since else { return base }
            return base.filter { $0.timestamp >= since }
        }()
        return Self.series(from: samples, metric: metric, limit: limit)
    }

    /// Stateless variant, so SwiftUI views can plot straight from an observed array without
    /// reaching into the store (and without needing the store to be observable).
    public static func series(from samples: [BatterySample],
                              metric: SampleMetric,
                              limit: Int = 600) -> [ChartPoint] {
        let raw: [(Date, Double)] = samples.compactMap { sample in
            guard let value = metric.value(from: sample) else { return nil }
            return (sample.timestamp, value)
        }
        return downsample(raw, limit: limit)
    }

    public enum Source { case live, archive }

    /// Buckets by index and averages, which preserves the visual shape while bounding work.
    public static func downsample(_ points: [(Date, Double)], limit: Int) -> [ChartPoint] {
        guard limit > 1, points.count > limit else {
            return points.enumerated().map { ChartPoint(id: $0.offset, date: $0.element.0, value: $0.element.1) }
        }
        let bucketSize = Double(points.count) / Double(limit)
        var result: [ChartPoint] = []
        result.reserveCapacity(limit)
        for bucket in 0..<limit {
            let start = Int(Double(bucket) * bucketSize)
            let end = min(points.count, max(start + 1, Int(Double(bucket + 1) * bucketSize)))
            guard start < end else { continue }
            var sum = 0.0
            for index in start..<end { sum += points[index].1 }
            let mid = (start + end) / 2
            result.append(ChartPoint(id: bucket, date: points[mid].0, value: sum / Double(end - start)))
        }
        return result
    }

    public var liveRange: ClosedRange<Date>? {
        guard let first = live.first?.timestamp, let last = live.last?.timestamp, first < last else { return nil }
        return first...last
    }

    public var archiveRange: ClosedRange<Date>? {
        guard let first = archive.first?.timestamp, let last = archive.last?.timestamp, first < last else { return nil }
        return first...last
    }

    // MARK: - Persistence

    private func loadArchive() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let cutoff = Date().addingTimeInterval(-archiveRetention)
        var loaded: [BatterySample] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            guard let sample = try? decoder.decode(BatterySample.self, from: Data(line)) else { continue }
            if sample.timestamp >= cutoff { loaded.append(sample) }
        }
        loaded.sort { $0.timestamp < $1.timestamp }
        archive = loaded
        lastArchiveWrite = loaded.last?.timestamp
    }

    private func persist(_ sample: BatterySample) {
        guard isPersistenceEnabled, let fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var line = try? encoder.encode(sample) else { return }
        line.append(0x0A)
        ioQueue.async {
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: line)
            } else {
                try? line.write(to: fileURL, options: .atomic)
            }
        }
    }
}

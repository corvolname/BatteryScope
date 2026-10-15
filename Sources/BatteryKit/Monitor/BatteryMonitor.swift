import Foundation
import Combine
import AppKit

/// The single observable source of truth for the UI.
///
/// Sampling is driven by a main-run-loop timer, and `PowerSourceWatcher` additionally forces
/// an immediate re-read on plug/unplug so the menu bar reacts instantly instead of waiting
/// out the sampling interval.
///
/// - Note: intended to be used from the main thread only.
public final class BatteryMonitor: ObservableObject {

    @Published public private(set) var snapshot: BatterySnapshot?
    @Published public private(set) var samples: [BatterySample] = []
    @Published public private(set) var trend = TrendEstimate()
    @Published public private(set) var lastReadAt: Date?
    @Published public private(set) var lastReadDuration: TimeInterval = 0
    public private(set) var readCount: Int = 0

    /// Memoised chart series, keyed by metric and invalidated when the sample buffer changes.
    ///
    /// Two ways of getting this wrong, both measured:
    ///
    /// * Calling `series(_:since:)` inside a view `body` recomputed it on every render — the card
    ///   asks four times per render, and each call filtered, mapped and downsampled the whole sample
    ///   buffer, for a rolling window whose start moved every time so nothing could ever be cached.
    /// * Rebuilding every metric eagerly on each read removed that cost but added work when nobody
    ///   was looking: idle CPU went from 1.0 % to 3.2 % because eight series were computed per
    ///   second for views that did not exist.
    ///
    /// So: computed on demand, but only once per batch of samples.
    private var seriesCache: [SampleMetric: [ChartPoint]] = [:]
    private var seriesCacheRevision = -1
    private var samplesRevision = 0

    /// Smoothed remaining-time estimates, republished at most once a minute. See
    /// `RemainingTimeStabilizer` for why they are not live.
    @Published public private(set) var timeToEmptyMinutes: Int?
    @Published public private(set) var timeToFullMinutes: Int?
    private var emptyStabilizer = RemainingTimeStabilizer()
    private var fullStabilizer = RemainingTimeStabilizer()
    /// True when the driver's change notification is registered, so reads happen on publish
    /// rather than only on the timer.
    public private(set) var isWatchingRegistry = false
    /// True when the SMC exposes CPU and GPU die sensors on this machine.
    public var hasDieTemperatures: Bool { thermalReader != nil }
    /// True when the ~1 Hz SMC power path is available, i.e. the power charts are live.
    public var hasLivePowerSensors: Bool { smcReader != nil }
    @Published public private(set) var isAvailable: Bool = true

    public let profile: SystemProfile
    public let history: HistoryStore

    /// Seconds between registry reads. The kernel refreshes the battery values about once a
    /// second, so 1 s is the fastest useful cadence and the default.
    /// Which battery-power reading to record and display.
    public var powerSource: BatterySnapshot.BatteryPowerSource = .automatic {
        didSet {
            guard powerSource != oldValue else { return }
            // The chosen source changes what a sample means; mixing them in one curve would
            // produce a step that never happened in the hardware.
            samples = []
            history.clearLive()
            readNow()
        }
    }

    public var samplingInterval: TimeInterval = 1 {
        didSet {
            guard samplingInterval != oldValue else { return }
            restartTimer()
        }
    }

    private var timer: Timer?
    private var watcher: PowerSourceWatcher?
    private var registryWatcher: BatteryRegistryWatcher?
    /// CPU/GPU die temperatures. The HID sensor sweep that used to run here every tick was
    /// removed: it cost 312 event copies per second to produce a number that could not be split
    /// into CPU and GPU anyway. `PMUHIDReader` is still available for diagnostics (and the `pmu`
    /// CLI command) but is no longer on the sampling path.
    private let thermalReader = SMCThermalReader()
    /// ~1 Hz direct-watt power readings. Retained for the same reason.
    private let smcReader = SMCPowerReader()
    /// Live CPU / GPU / memory load — public API, no SMC keys, and the only readings here that
    /// change appreciably inside one second besides the power figures.
    private let systemLoadReader = SystemLoadReader()
    private var observers: [NSObjectProtocol] = []
    /// The metric window used for the derived ETA; long enough to beat gauge noise.
    public var trendWindow: TimeInterval = 300

    public init(historyFileURL: URL? = HistoryStore.defaultFileURL()) {
        self.profile = SystemInfoReader.read()
        self.history = HistoryStore(fileURL: historyFileURL)
        self.samples = history.live
    }

    deinit {
        timer?.invalidate()
        watcher?.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Lifecycle

    public func start() {
        guard timer == nil else { return }
        watcher = PowerSourceWatcher { [weak self] in
            self?.readNow()
        }
        watcher?.start()

        // Push, not poll: the driver tells us the instant it republishes, so a change shows up
        // immediately instead of up to one polling interval later.
        let registryWatcher = BatteryRegistryWatcher { [weak self] in
            self?.readNow()
        }
        registryWatcher.start()
        self.registryWatcher = registryWatcher

        // Sleep/wake leaves the timer stale and the readings cold; refresh on both.
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.readNow()
            self?.restartTimer()
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            self?.readNow()
        })

        isWatchingRegistry = self.registryWatcher?.isWatching ?? false
        readNow()
        restartTimer()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        watcher?.stop()
        watcher = nil
        registryWatcher?.stop()
        registryWatcher = nil
    }

    private func restartTimer() {
        timer?.invalidate()
        let interval = max(0.5, samplingInterval)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.readNow()
        }
        // A tolerance lets the system coalesce wakeups, which matters for a always-on agent.
        timer.tolerance = min(0.5, interval * 0.2)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Reading

    public func readNow() {
        let started = Date()
        let snapshot = BatteryReader.read()
        lastReadDuration = Date().timeIntervalSince(started)
        lastReadAt = started
        readCount += 1

        guard var snapshot else {
            // A Mac without a battery (Mac mini, Mac Studio, iMac) is not an error state.
            isAvailable = false
            self.snapshot = nil
            return
        }
        isAvailable = true
        // The PMU sensors come from a different, much faster path than the battery node, so they
        // are read separately and attached here.
        snapshot.thermal = thermalReader?.read()
        snapshot.smcPower = smcReader?.read()
        snapshot.systemLoad = systemLoadReader.read()
        self.snapshot = snapshot
        refreshTimeEstimates(for: snapshot)

        let sample = BatterySample(timestamp: snapshot.timestamp, snapshot: snapshot,
                                   powerSource: powerSource)
        history.append(sample)
        samples = history.live
        trend = TrendEstimator.estimate(from: history.live, window: trendWindow, now: snapshot.timestamp)
        // Invalidates the memoised chart series; the next view that asks recomputes it.
        samplesRevision &+= 1
    }

    // MARK: - Derived conveniences

    public var estimatedMinutesToEmpty: Int? {
        trend.minutesToEmpty
    }

    public var estimatedMinutesToFull: Int? {
        trend.minutesToFull
    }

    /// Width of the rolling window the card charts cover.
    public static let chartWindow: TimeInterval = 600

    /// Chart data for one metric over the rolling window.
    ///
    /// Safe to call from a view `body`: the result is memoised until the next batch of samples
    /// arrives, so four charts cost four computations per second at most — and none at all while no
    /// chart is on screen.
    public func chartSeries(_ metric: SampleMetric,
                            window: TimeInterval = BatteryMonitor.chartWindow) -> [ChartPoint] {
        if seriesCacheRevision != samplesRevision {
            seriesCache.removeAll(keepingCapacity: true)
            seriesCacheRevision = samplesRevision
        }
        if let cached = seriesCache[metric] { return cached }
        let cutoff = Date().addingTimeInterval(-window)
        let points = HistoryStore.series(from: samples.filter { $0.timestamp >= cutoff },
                                         metric: metric, limit: 600)
        seriesCache[metric] = points
        return points
    }

    /// Stabilised time-to-empty. Prefers the system's own estimate (powerd already models the
    /// average draw) and falls back to the gauge's, then to the measured capacity trend.
    public var bestTimeToEmptyMinutes: Int? { timeToEmptyMinutes }

    /// Stabilised time-to-full, same preference order.
    public var bestTimeToFullMinutes: Int? { timeToFullMinutes }

    private func refreshTimeEstimates(for snapshot: BatterySnapshot) {
        let charging = snapshot.isCharging || (snapshot.externalConnected
                                               && snapshot.isBatteryActivelyMovingCharge)
        let rawEmpty = snapshot.systemTimeToEmptyMinutes
            ?? snapshot.gaugeTimeToEmptyMinutes
            ?? trend.minutesToEmpty
        let rawFull = snapshot.systemTimeToFullMinutes
            ?? snapshot.gaugeTimeToFullMinutes
            ?? trend.minutesToFull

        if charging {
            emptyStabilizer.reset()
            timeToEmptyMinutes = nil
            timeToFullMinutes = fullStabilizer.update(raw: rawFull)
        } else {
            fullStabilizer.reset()
            timeToFullMinutes = nil
            timeToEmptyMinutes = emptyStabilizer.update(raw: rawEmpty)
        }
    }

    public func series(_ metric: SampleMetric, since: Date? = nil, limit: Int = 600) -> [ChartPoint] {
        let source: [BatterySample]
        if let since {
            source = samples.filter { $0.timestamp >= since }
        } else {
            source = samples
        }
        return HistoryStore.series(from: source, metric: metric, limit: limit)
    }

    public var archiveSeries: [BatterySample] { history.archive }
}

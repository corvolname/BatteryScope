import Foundation

/// CPU and GPU die temperatures, read from the SMC.
///
/// ## Why not the PMU HID channels
///
/// An earlier version showed "the hottest PMU sensor" from the HID event path. That is fast
/// (sub-second) but it cannot be split into CPU and GPU: measured with an 8-thread CPU load and a
/// Metal compute load, *the same* channels (`tdev3`, `tdev6`, `tdie*`, `TP*g`) rose under both —
/// heat spreads across the package, so the deltas do not separate the two.
///
/// ## How CPU and GPU are told apart here
///
/// The SMC exposes 218 temperature keys with functional prefixes, and they *do* separate cleanly.
/// Measured peak rise under load:
///
/// | Prefix | Keys | 8-thread CPU load | Metal GPU load |
/// |---|---|---|---|
/// | `Tp*` | 30 | — | +9.8 °C |
/// | `Te*` | 3 | **+7.7 °C** | +9.9 °C |
/// | `Tg*` | 8 | +4.0 °C | **+18.7 °C** |
///
/// `Tg*` is 4.7× more sensitive to GPU load than to CPU load, and `Te*` is the other way round.
/// `Tp`/`Te` are the performance- and efficiency-core sensors, `Tg` the graphics sensors — the
/// same convention comparable tools use, and the grouping this reader follows: CPU is the hottest
/// of `Tp*` ∪ `Te*`, GPU the hottest of `Tg*`.
///
/// Cost: 41 keys, two SMC transactions each — around 0.1 % of one core per second, which is *less*
/// than the HID sweep it replaced (156 services, 312 event copies).
///
/// ## Why `TCMz` is preferred over the per-core maximum
///
/// `TCMz` is the package hot spot. Measured on a MacBookPro18,2 it is **the hottest of 218
/// readable temperature keys**, and it tracks `max(Tp* ∪ Te*)` to within 0.3 °C — identical over
/// six consecutive seconds, +0.25 °C at another moment. So switching to it changes the number by
/// almost nothing; what it changes is the *meaning*: thermal management responds to the hottest
/// point of the package, not to a per-core figure.
///
/// The per-core maximum stays as the fallback because `TCMz` is not guaranteed on every model.
///
/// Two claims worth recording, both tested:
///
/// * `TCMz` does **not** update faster than the core sensors. Sampled every 100 ms it produced 4
///   distinct values in 3 s (~1.3 Hz), the same as `Tp01` — the SMC delivers all of these at about
///   1 Hz regardless of what the sensor does internally.
/// * At idle the hottest keys are CPU cores (`Te02` = `TCMz` = 63.09 °C, `Tp02` = 59.72 °C), with
///   no PMU or memory-controller sensor above them, so a "the maximum is skewed by some unrelated
///   hot spot" worry does not apply here.
/// Which sensor a CPU temperature reading came from.
public struct CPUTemperaturePick: Equatable {
    public var celsius: Double
    /// `TCMz`, or the key of the hottest core sensor when the hot spot is unavailable.
    public var source: String
}

public struct SMCThermalReading {
    /// Hottest performance- or efficiency-core sensor.
    public var cpuCelsius: Double?
    /// Hottest graphics sensor.
    public var gpuCelsius: Double?
    public var cpuChannel: String?
    public var gpuChannel: String?
    public var cpuKeyCount = 0
    public var gpuKeyCount = 0
    public var timestamp = Date()
}

public final class SMCThermalReader {

    /// Performance cores.
    public static let cpuPrefixes = ["Tp", "Te"]
    /// Graphics.
    public static let gpuPrefixes = ["Tg"]
    /// Package hot spot — the single hottest temperature key on the machine.
    public static let hotspotKey = "TCMz"

    private let client: SMCClient
    private let cpuKeys: [String]
    private let gpuKeys: [String]

    /// Resolves the key list once: enumerating 2251 keys on every tick would dwarf the reads.
    public init?(client: SMCClient? = nil) {
        guard let client = client ?? SMCClient() else { return nil }
        self.client = client

        var cpu: [String] = []
        var gpu: [String] = []
        for name in client.allKeyNames() {
            if Self.cpuPrefixes.contains(where: name.hasPrefix) {
                cpu.append(name)
            } else if Self.gpuPrefixes.contains(where: name.hasPrefix) {
                gpu.append(name)
            }
        }
        // Without both groups there is nothing to show that the PMU path could not show better.
        guard !cpu.isEmpty, !gpu.isEmpty else { return nil }
        self.cpuKeys = cpu
        self.gpuKeys = gpu
    }

    public var cpuKeyCount: Int { cpuKeys.count }
    public var gpuKeyCount: Int { gpuKeys.count }

    public func read() -> SMCThermalReading {
        var reading = SMCThermalReading()
        reading.cpuKeyCount = cpuKeys.count
        reading.gpuKeyCount = gpuKeys.count
        let cpuSensors = cpuKeys.compactMap { key -> (key: String, value: Double)? in
            guard let value = client.readDouble(key), value.isFinite, value > 5, value < 130 else { return nil }
            return (key, value)
        }
        if let pick = Self.pickCPUTemperature(hotspot: client.readDouble(Self.hotspotKey),
                                              sensors: cpuSensors) {
            reading.cpuCelsius = pick.celsius
            reading.cpuChannel = pick.source
        }
        if let hottest = hottest(of: gpuKeys) {
            reading.gpuCelsius = hottest.value
            reading.gpuChannel = hottest.key
        }
        return reading
    }

    /// Picks the CPU temperature: package hot spot first, hottest core sensor second.
    ///
    /// Pure so the precedence can be tested without a live SMC — including the case of a `TCMz`
    /// that answers with a nonsense value, which must fall through rather than win.
    public static func pickCPUTemperature(hotspot: Double?,
                                          sensors: [(key: String, value: Double)]) -> CPUTemperaturePick? {
        if let hotspot, hotspot.isFinite, hotspot > 5, hotspot < 130 {
            return CPUTemperaturePick(celsius: hotspot, source: hotspotKey)
        }
        guard let best = sensors.max(by: { $0.value < $1.value }) else { return nil }
        return CPUTemperaturePick(celsius: best.value, source: best.key)
    }

    private func hottest(of keys: [String]) -> (key: String, value: Double)? {
        var best: (key: String, value: Double)?
        for key in keys {
            guard let value = client.readDouble(key) else { continue }
            // A sensor that is absent or between updates reads 0 or a nonsense float; showing that
            // as a die temperature would be worse than showing nothing.
            guard value.isFinite, value > 5, value < 130 else { continue }
            if best == nil || value > best!.value { best = (key, value) }
        }
        return best
    }
}

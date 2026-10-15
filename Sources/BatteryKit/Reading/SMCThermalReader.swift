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
        if let hottest = hottest(of: cpuKeys) {
            reading.cpuCelsius = hottest.value
            reading.cpuChannel = hottest.key
        }
        if let hottest = hottest(of: gpuKeys) {
            reading.gpuCelsius = hottest.value
            reading.gpuChannel = hottest.key
        }
        return reading
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

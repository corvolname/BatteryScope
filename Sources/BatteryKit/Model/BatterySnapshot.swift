import Foundation

/// Battery condition buckets, mirroring how macOS presents "Condition".
public enum BatteryCondition: String {
    case normal
    case serviceRecommended
    case unknown

    public var displayName: String {
        switch self {
        case .normal: return "正常"
        case .serviceRecommended: return "建议维修"
        case .unknown: return "未知"
        }
    }
}

/// A complete, point-in-time reading of the battery and everything feeding it.
public struct BatterySnapshot {
    public init() {}


    public var timestamp: Date = Date()

    // MARK: Identity

    public var deviceName: String?
    public var serial: String?
    public var manufacturerData: ManufacturerData?
    public var manufactureDate: ManufactureDateDecoder.Decoded?
    public var hardwareRevision: String?
    public var firmwareVersion: String?

    // MARK: Charge state

    public var chargePercent: Double?
    public var maxCapacityPercent: Int?
    public var stateOfChargePercent: Double?
    public var isCharging: Bool = false
    public var fullyCharged: Bool = false
    public var externalConnected: Bool = false
    public var externalChargeCapable: Bool = false
    public var atCriticalLevel: Bool = false
    public var isPresent: Bool = true
    public var batteryInstalled: Bool = true

    // MARK: Capacity (mAh)

    public var designCapacityMAh: Int?
    public var maxCapacityMAh: Int?
    public var nominalCapacityMAh: Int?
    public var currentCapacityMAh: Int?
    public var absoluteCapacityMAh: Int?

    // MARK: Electrical

    public var voltageVolts: Double?
    public var amperageAmps: Double?
    public var temperatureCelsius: Double?
    public var virtualTemperatureCelsius: Double?

    // MARK: Cycles

    public var cycleCount: Int?
    public var designCycleCount: Int?

    // MARK: Time estimates (minutes)

    public var systemTimeToEmptyMinutes: Int?
    public var systemTimeToFullMinutes: Int?
    public var gaugeTimeToEmptyMinutes: Int?
    public var gaugeTimeToFullMinutes: Int?
    public var rawTimeRemainingMinutes: Int?

    // MARK: Diagnostics

    public var permanentFailureStatus: Int?
    public var batteryHealthMetric: Int?
    public var faultType: Int?
    public var batteryCellDisconnectCount: Int?

    // MARK: Attached hardware

    public var adapter: AdapterSnapshot?
    public var charger: ChargerSnapshot?
    public var telemetry: PowerTelemetry?
    public var powerDistribution: PowerDistribution?
    public var banks: [BankSnapshot] = []
    public var lifetime: LifetimeStats?

    /// When the driver last republished this whole node, from `AppleSmartBattery.UpdateTime`
    /// (a Unix timestamp).
    ///
    /// Measured on a MacBookPro18,2 running macOS 27: the node is republished only every
    /// **30–60 seconds**, and *every* value in it — voltage, amperage, temperature, cell
    /// voltages, `SystemPowerIn`, `SystemLoad` — changes together at that moment. Nothing in
    /// this node updates once per second, so this timestamp is the honest "measured at" time
    /// for all of the readings above, and the reason a 1-second poll shows plateaus.
    public var registryUpdateTime: Date?

    /// How old the current reading is. Shown in the UI so a lagging value is never mistaken for
    /// a live one.
    public var dataAge: TimeInterval? {
        registryUpdateTime.map { Date().timeIntervalSince($0) }
    }

    // MARK: Raw

    /// Live SMC readings (`PSTR` / `PDTR` / `B0AC`×`B0AV` / `TB0T` / `F0Ac`).
    ///
    /// **All three power figures come from here, and from nothing else.** Two earlier arrangements
    /// were both wrong, in opposite directions:
    ///
    /// 1. Mixing sources — system power from the SMC, battery power from the `AppleSmartBattery`
    ///    node. The two refresh on different clocks, so during any change the card showed
    ///    contradictions: 整机 9.37 W beside 电池 −20.32 W, numbers that cannot both be true when
    ///    the battery is supplying the machine.
    /// 2. Taking all three from the node. Self-consistent, but the node holds its telemetry for tens
    ///    of seconds, so the card sat frozen while a comparable readout moved every second.
    ///
    /// The SMC has both properties at once. Sampled every second: `PSTR` 21.91 → 21.54 → 24.71 →
    /// 21.82, `B0AC` −1725 → −1979 → −1745 mA — live — and `PDTR ≈ PSTR + B0AC×B0AV` holds within a
    /// couple of watts, the residue being the load's real movement between the two reads.
    public var smcPower: SMCPowerReading?

    /// Live CPU / GPU / memory load. Same reasoning as `smcPower`: sampled separately and attached,
    /// because these move every second and belong on the live charts.
    public var systemLoad: SystemLoadReading?

    /// 整机功耗 in watts — SMC `PSTR`, else the battery node.
    public var liveSystemLoadWatts: Double? { smcPower?.systemWatts ?? systemLoadWatts }
    /// 适配器供电 in watts — SMC `PDTR`, else the battery node.
    public var liveAdapterInputWatts: Double? { smcPower?.adapterWatts ?? adapterInputWatts }

    /// 电池功率 in watts, with the sign pointing into the battery (charging positive).
    ///
    /// From the battery node, **not** from the SMC's `PPBR`.
    ///
    /// `PPBR` was used here on the strength of its update rate, with the node supplying only the
    /// sign. Measurement says that was wrong while charging. Read at the same instant, and checked
    /// against the conservation law (adapter in = system load + battery):
    ///
    /// | time | SMC `PPBR` | node `BatteryPower` | `V × A` | `SystemLoad + battery` vs `SystemPowerIn` |
    /// |---|---|---|---|---|
    /// | 21:13:21 | 1.71 | **7.16** | 6.87 | 25.75 + 7.16 = 32.91 = 32.91 ✓ |
    /// | 21:13:47 | 1.77 | **6.32** | 6.32 | 26.37 + 6.32 = 32.69 = 32.69 ✓ |
    /// | 21:14:13 | 1.70 | **6.32** | 6.32 | 26.37 + 6.32 = 32.69 = 32.69 ✓ |
    ///
    /// `PPBR` is roughly a quarter of the truth while charging, and it moves *opposite* to it
    /// (1.71 where the node reads 7.16, 1.77 where it reads 6.32) — it is a different quantity, not
    /// a scaled one. `PSTR` and `PDTR` do satisfy the law together with the node's value, which is
    /// why those two stay on the SMC.
    public var liveBatteryPowerWatts: Double? {
        // The SMC's own battery power (B0AC × B0AV) when the machine exposes it: live, and from the
        // same clock as the system and adapter figures beside it.
        smcPower?.batteryWatts ?? effectiveBatteryPowerWatts
    }

    /// True when the battery power shown comes from the SMC rather than the battery node.
    public var hasLiveBatteryPower: Bool { smcPower?.batteryWatts != nil }

    /// 电池温度 in °C — SMC `TB0T` when available, otherwise the register.
    public var liveBatteryTemperatureCelsius: Double? { smcPower?.batteryTemperatureCelsius ?? temperatureCelsius }
    /// 风扇转速 in rpm. Only the SMC exposes this.
    public var fanRPM: Double? { smcPower?.fanRPM }
    /// True when the power figures come from the ~1 Hz SMC rather than the 30–60 s registers.
    public var hasLivePowerSource: Bool { smcPower != nil }

    /// CPU and GPU die temperatures from the SMC. See `SMCThermalReader` for why these come from
    /// the SMC rather than the faster PMU HID channels: the HID channels cannot be split into CPU
    /// and GPU, because both loads heat the same sensors.
    public var thermal: SMCThermalReading?

    /// Hottest performance/efficiency core sensor, in °C.
    public var cpuTemperatureCelsius: Double? { thermal?.cpuCelsius }
    /// Hottest graphics sensor, in °C.
    public var gpuTemperatureCelsius: Double? { thermal?.gpuCelsius }

    /// The full captured IORegistry subtree, for the raw key browser.
    public var registryTree: RegistryNode?

    // MARK: - Derived values

    /// Signed battery current in watts: positive = charging, negative = discharging.
    ///
    /// The gas gauge's sign convention is normalised defensively: a battery that is not
    /// connected to external power can never be charging, so a positive amperage in that
    /// state is a known firmware sign inversion and gets flipped.
    public var chargePowerWatts: Double? {
        guard let v = voltageVolts, let a = amperageAmps else { return nil }
        return v * a
    }

    /// Battery power as reported by the PMU telemetry counters (positive = charging).
    public var telemetryBatteryPowerWatts: Double? { telemetry?.batteryPowerWatts }

    /// A battery power reading together with where it came from, because on Apple Silicon the
    /// registers and the telemetry counters disagree more often than one would hope and the UI
    /// must be able to say which figure it is showing.
    public struct PowerMeasurement {
        public var watts: Double
        public var source: PowerMeasurementSource
    }

    public enum PowerMeasurementSource: String {
        case telemetry = "PMU 遥测"
        case amperage = "电压 × 电流"
        case systemLoad = "整机负载推算"
        case unavailable = "不可用"
    }

    /// Which battery-power reading to trust.
    ///
    /// The two independent measured sources disagree slightly (`PowerTelemetryData.BatteryPower`
    /// versus `Voltage × InstantAmperage`), so which one is shown is a user choice rather than a
    /// silent decision — and the derived fallback can be switched off entirely.
    public enum BatteryPowerSource: String, CaseIterable, Identifiable {
        /// Independent measurements first, then the load-derived fallback.
        case automatic
        /// The gauge registers only: `Voltage × InstantAmperage`, raw and un-smoothed.
        case registers
        /// Independent measurements only. Never adds or subtracts to invent a value.
        case measuredOnly

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .automatic: return "自动（测量优先）"
            case .registers: return "电压 × 电流"
            case .measuredOnly: return "仅实测（禁止推算）"
            }
        }
    }

    /// Best available battery power for the chosen source, with explicit provenance.
    ///
    /// Observed on a MacBookPro18,2 running macOS 27 while the machine was genuinely
    /// discharging: `Amperage`, `InstantAmperage` **and** `PowerTelemetryData.BatteryPower`
    /// all read `0`, while `SystemPowerIn`/`SystemLoad` reported ~36 W. That is why the
    /// load-derived fallback exists, and why it can be turned off.
    public func batteryPower(using source: BatteryPowerSource) -> PowerMeasurement? {
        func fromTelemetry() -> PowerMeasurement? {
            guard let telemetry = telemetryBatteryPowerWatts, abs(telemetry) > 0.05 else { return nil }
            return PowerMeasurement(watts: telemetry, source: .telemetry)
        }
        func fromRegisters() -> PowerMeasurement? {
            guard let amperage = amperageAmps, abs(amperage) > 0.001, let watts = chargePowerWatts
            else { return nil }
            return PowerMeasurement(watts: watts, source: .amperage)
        }

        switch source {
        case .registers:
            return fromRegisters() ?? fromTelemetry()
        case .measuredOnly:
            return fromTelemetry() ?? fromRegisters()
        case .automatic:
            if let measurement = fromTelemetry() { return measurement }
            if let measurement = fromRegisters() { return measurement }
            // On battery the system load can only be coming from the battery, so it is a sound
            // proxy when the current registers read zero. Reported as negative (discharging).
            if !externalConnected, let load = systemLoadWatts, load > 0.05 {
                return PowerMeasurement(watts: -load, source: .systemLoad)
            }
            // Plugged in with the gauge reporting nothing: idle, or charging paused.
            if externalConnected, let watts = chargePowerWatts {
                return PowerMeasurement(watts: watts, source: .amperage)
            }
            return nil
        }
    }

    /// Default view: measurements first, derivation only as a last resort.
    public var effectiveBatteryPower: PowerMeasurement? { batteryPower(using: .automatic) }

    /// Best available battery power reading, preferring the hardware telemetry counter.
    public var effectiveBatteryPowerWatts: Double? { effectiveBatteryPower?.watts }

    /// True when the reported battery power had to be derived rather than measured.
    public var isBatteryPowerDerived: Bool {
        effectiveBatteryPower?.source == .systemLoad
    }

    /// Below this the battery is neither meaningfully charging nor discharging.
    public static let idlePowerThresholdWatts = 0.5

    /// True while the battery is actually moving charge.
    ///
    /// Used to decide whether a battery-power chart is worth showing at all: on AC with a full
    /// or paused battery the reading is a constant 0 W, and a flat line at zero is noise rather
    /// than information.
    public var isBatteryActivelyMovingCharge: Bool {
        guard let power = effectiveBatteryPowerWatts else { return false }
        return abs(power) >= Self.idlePowerThresholdWatts
    }

    /// Power actually drawn through the adapter input stage (not the charger's rating).
    public var adapterInputWatts: Double? { telemetry?.actualInputWatts }

    public var systemLoadWatts: Double? { telemetry?.systemLoadWatts }

    /// Energy that never reaches the system, i.e. charger + conversion losses.
    public var adapterEfficiencyDeltaWatts: Double? {
        guard let input = adapterInputWatts, let load = systemLoadWatts else { return nil }
        return max(0, input - load)
    }

    /// Battery health using **measured** values only: the full-charge capacity the gauge
    /// actually achieved divided by the capacity the pack was designed for.
    ///
    /// `NominalChargeCapacity` is deliberately not used here. It is a gauge-side model rather
    /// than a measurement, and mixing it in would present a computed "标称" figure as if it were
    /// the real health of the pack.
    public var healthPercent: Double? {
        guard let design = designCapacityMAh, design > 0,
              let achieved = maxCapacityMAh, achieved > 0 else { return nil }
        return Double(achieved) / Double(design) * 100
    }

    /// Capacity already lost relative to the design capacity, in mAh (measured).
    public var capacityFadeMAh: Int? {
        guard let design = designCapacityMAh, let achieved = maxCapacityMAh else { return nil }
        return max(0, design - achieved)
    }

    public var cycleUsagePercent: Double? {
        guard let cycles = cycleCount, let design = designCycleCount, design > 0 else { return nil }
        return Double(cycles) / Double(design) * 100
    }

    public var condition: BatteryCondition {
        if let failure = permanentFailureStatus, failure != 0 { return .serviceRecommended }
        if let health = healthPercent, health < 80 {
            return .serviceRecommended
        }
        if designCapacityMAh == nil { return .unknown }
        return .normal
    }

    public var powerSourceDescription: String {
        if isCharging { return "正在充电" }
        if externalConnected && fullyCharged { return "已充满（接通电源）" }
        if externalConnected { return "已接通电源（未充电）" }
        return "使用电池"
    }

    /// Warnings the user can act on, derived from charger diagnostics + temperature.
    ///
    /// No raw register values in the text. The diagnostics are firmware bitfields whose bits Apple
    /// does not document — `ChargerHwIlimBackoffReason = 16`, say, cannot be translated into a cause
    /// by anyone outside Apple, so printing it asks the reader to interpret a number that has no
    /// readable meaning. Each note states what is happening in plain language instead.
    ///
    /// `ChargerHwIlimBackoffReason` is not reported at all any more. It was firing as a 提示 while
    /// the battery sat fully charged with `IsCharging = 0` and `ChargingCurrent = 0`, which is the
    /// normal state in which the charger IC winds its input limit back because there is nothing left
    /// to charge. "限流回退" also reads like a fault, so the note alarmed without informing and the
    /// user could not act on it.
    public var advisories: [String] {
        var notes: [String] = []
        if let temp = temperatureCelsius, temp >= 40 {
            notes.append(String(format: "电池温度偏高（%.1f°C），充电速度可能被限制。", temp))
        }
        if let reason = charger?.slowChargingReason, reason != 0 {
            notes.append("充电器报告充电速度较慢。")
        }
        if let inhibit = charger?.inhibitReason, inhibit != 0 {
            notes.append("充电已暂停，可能是温度或电源策略所致。")
        }
        // A lifetime counter; a bare number of seconds is not a unit anyone reads.
        let thermallyLimited = charger?.timeChargingThermallyLimitedSeconds ?? 0
        if thermallyLimited >= 60 {
            let minutes = thermallyLimited / 60
            notes.append(minutes >= 60
                        ? "累计因温度受限充电约 \(minutes / 60) 小时。"
                        : "累计因温度受限充电约 \(minutes) 分钟。")
        }
        if condition == .serviceRecommended {
            notes.append("电池健康度低于 80% 或存在永久性故障标记，建议检修。")
        }
        if let adapter = adapter, let rated = adapter.effectiveRatedWatts,
           let negotiated = adapter.negotiatedWatts, negotiated < rated - 1 {
            notes.append(String(format: "充电器标称 %.0fW，当前协商 %.1fW（受线缆、端口或电源策略影响）。",
                                rated, negotiated))
        }
        return notes
    }
}

// MARK: - Charging diagnostics decoding

/// Human explanations for the charger's `NotChargingReason` bitfield.
///
/// The exact bit semantics are not publicly documented; values below are the ones that
/// have been observed to line up with a matching system state. Anything unrecognised is
/// shown as raw hex instead of being guessed at.
public enum ChargingDiagnostics {

    public static func notChargingReasonLabel(_ value: UInt32?) -> String? {
        guard let value else { return nil }
        if value == 0 { return "充电未被阻止" }
        if let known = knownReasons[value] { return known }
        return nil
    }

    public static func hex(_ value: UInt32?) -> String? {
        guard let value else { return nil }
        return "0x" + String(format: "%08X", value)
    }

    private static let knownReasons: [UInt32: String] = [
        0x0000_0001: "充电器未提供足够的电源",
        0x0100_0000: "已达充电上限或当前无需充电（含电池健康管理暂停）",
        0x0200_0000: "电池温度不在允许充电区间",
        0x0400_0000: "电池未接入或通信异常",
    ]
}

import Foundation

/// A USB-PD contract advertised by the attached charger.
public struct PDContract {
    public init() {}

    public var index: Int?
    public var maxVoltageVolts: Double?
    public var maxCurrentAmps: Double?
    public var watts: Double? {
        guard let v = maxVoltageVolts, let a = maxCurrentAmps else { return nil }
        return v * a
    }
}

/// Everything `AppleSmartBattery` publishes about the attached power adapter.
public struct AdapterSnapshot {
    public init() {}

    public var name: String?
    public var manufacturer: String?
    public var model: String?
    public var serial: String?
    public var firmwareVersion: String?
    public var hardwareVersion: String?
    public var descriptionText: String?
    public var adapterID: Int?
    public var familyCode: UInt64?
    public var powerTier: Int?
    public var isWireless: Bool?

    /// The wattage printed on the charger, as reported by the charger itself.
    public var ratedWatts: Double?
    /// Voltage the charger is currently contracted at (volts).
    public var negotiatedVoltageVolts: Double?
    /// Current the charger is currently contracted at (amps).
    public var negotiatedCurrentAmps: Double?
    /// `negotiatedVoltageVolts × negotiatedCurrentAmps` — the live PD contract ceiling.
    public var negotiatedWatts: Double?

    public var contracts: [PDContract] = []

    /// Highest wattage in the advertised PDO menu, i.e. what the charger *could* deliver.
    public var maxMenuWatts: Double? {
        contracts.compactMap(\.watts).max()
    }

    /// A one-line label that always says something useful.
    ///
    /// `Name` is one of the adapter keys that the firmware only publishes intermittently, so
    /// this falls back through the generic description and finally to the wattage.
    public var displayName: String? {
        if let name, !name.isEmpty { return name }
        if let ratedWatts, let descriptionText, !descriptionText.isEmpty {
            return String(format: "%@（%.0fW）", descriptionText, ratedWatts)
        }
        if let descriptionText, !descriptionText.isEmpty { return descriptionText }
        if let ratedWatts { return String(format: "%.0fW 电源适配器", ratedWatts) }
        if let negotiatedWatts { return String(format: "约 %.0fW 电源适配器", negotiatedWatts) }
        return nil
    }

    /// Wattage to show as "the charger's rating": prefers the self-reported rating and falls
    /// back to the live PD contract so the figure is never blank while a charger is attached.
    public var effectiveRatedWatts: Double? {
        ratedWatts ?? negotiatedWatts
    }
}

/// `PowerTelemetryData` — the SMC/PMU power-flow counters. These are the numbers macOS
/// itself uses for its energy accounting, and they are the most trustworthy source for
/// "how many watts are actually flowing right now".
public struct PowerTelemetry {
    public init() {}

    public var systemPowerInMW: Int?
    public var systemLoadMW: Int?
    public var systemVoltageInMV: Int?
    public var systemCurrentInMA: Int?
    public var batteryPowerMW: Int?
    public var adapterEfficiencyLossMW: Int?
    public var wallEnergyEstimateMW: Int?
    public var systemEnergyConsumedMW: Int?
    public var powerTelemetryErrorCount: Int?

    public var actualInputWatts: Double? { systemPowerInMW.map { Double($0) / 1000 } }
    public var systemLoadWatts: Double? { systemLoadMW.map { Double($0) / 1000 } }
    public var batteryPowerWatts: Double? { batteryPowerMW.map { Double($0) / 1000 } }
    /// Clamped at zero: the counter is a smoothed delta that occasionally dips negative,
    /// which has no meaning as "negative loss".
    public var efficiencyLossWatts: Double? { adapterEfficiencyLossMW.map { max(0, Double($0) / 1000) } }
}

/// `PowerDistribution` — read-only view of the PMU's power budgeting decisions.
public struct PowerDistribution {
    public init() {}

    public var inputPowerMW: Int?
    public var inputCurrentMA: Int?
    public var inputVoltageMV: Int?
    public var wattageOverrideMW: Int?
    public var chargingAllowed: Bool?
    public var ratio: Int?

    public var inputWatts: Double? { inputPowerMW.map { Double($0) / 1000 } }
}

/// `AppleChargerData.ChargerData` — the charger's own telemetry registers.
public struct ChargerSnapshot {
    public init() {}

    public var chargerID: Int?
    public var chargingVoltageVolts: Double?
    public var chargingCurrentAmps: Double?
    public var vbusVolts: Double?
    public var ibusAmps: Double?
    public var chargerPowerWatts: Double?
    public var efficiency: Double?
    public var accumulatedEfficiency: Double?
    public var pmuConfiguration: Int?
    public var pmuConfigured: Int?
    public var notChargingReason: UInt32?
    public var slowChargingReason: UInt32?
    public var inhibitReason: UInt32?
    public var hardwareILimitBackoffReason: UInt32?
    public var timeChargingThermallyLimitedSeconds: Int?
    public var resetCounter: Int?

    public var targetChargePowerWatts: Double? {
        guard let v = chargingVoltageVolts, let a = chargingCurrentAmps else { return nil }
        return v * a
    }
}

/// One `AppleSmartBatteryBank`, i.e. one parallel cell group of the pack.
public struct BankSnapshot: Identifiable {
    public init() {}

    public var id: Int { bankID ?? -1 }
    public var bankID: Int?
    public var packID: Int?
    public var cellVoltageVolts: Double?
    public var qmaxMAh: Int?
    public var weightedRa: Double?
    public var presentDOD: Int?
    public var dod0: Int?
    public var cellCurrentAmps: [Double] = []
}

/// `BatteryData.LifetimeData` — lifetime extremes recorded by the gas gauge. This is the
/// closest thing to a "battery history report" that the hardware keeps for you.
public struct LifetimeStats {
    public init() {}

    public var totalOperatingTimeMinutes: Int?
    public var cycleCountLastQmax: Int?
    public var temperatureSampleCount: Int?
    public var averageTemperatureCelsius: Double?
    public var minimumTemperatureCelsius: Double?
    public var maximumTemperatureCelsius: Double?
    public var minimumPackVoltageVolts: Double?
    public var maximumPackVoltageVolts: Double?
    public var maximumChargeCurrentAmps: Double?
    public var maximumDischargeCurrentAmps: Double?
    public var rdisCount: Int?

    public var totalOperatingHours: Double? {
        totalOperatingTimeMinutes.map { Double($0) / 60 }
    }
}

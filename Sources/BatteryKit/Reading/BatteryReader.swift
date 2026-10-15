import Foundation
import IOKit

/// Builds a `BatterySnapshot` from the IORegistry.
///
/// ## Where the numbers actually live
///
/// This is the part that trips up naive `ioreg` pipelines. On Apple Silicon the top level
/// of `AppleSmartBattery` does **not** contain `Temperature`, `DesignCapacity`,
/// `AppleRawMaxCapacity` or `ManufactureDate` — those are nested inside
/// `AppleSmartBatteryPack` → `BatteryData`. A `ioreg -rn AppleSmartBattery | grep '"DesignCapacity"'`
/// therefore misses them entirely:
///
/// ```
/// AppleSmartBattery
/// ├── BatteryData            { DesignCapacity, FullChargeCapacity, NominalChargeCapacity,
/// │                           RemainingCapacity, CurrentCapacity, MaxCapacity }
/// ├── AdapterDetails         { Watts, Current, AdapterVoltage, Name, Manufacturer, UsbHvcMenu }
/// ├── PowerTelemetryData     { SystemPowerIn, SystemLoad, BatteryPower, ... }
/// ├── PowerDistribution      { IPDInputPower, IPDChargingAllowed, ... }
/// ├── AppleChargerData ──┐
/// ├── AppleSmartBatteryPack
/// │   ├── BatteryData       { Temperature, CycleCount, AppleRawMaxCapacity,
/// │   │                       AppleRawCurrentCapacity, DesignCapacity, MfgData,
/// │   │                       ManufactureDate, StateOfCharge, LifetimeData }
/// │   └── AppleSmartBatteryBank × 3
/// │       ├── BatteryData   { CellVoltage, Qmax, WeightedRa, PresentDOD, DOD0 }
/// │       └── AppleSmartBatteryCell × 2  { CellCurrent }
/// ```
///
/// The reader therefore layers `Pack.BatteryData` → `Battery.BatteryData` → `AppleSmartBattery`
/// so one code path serves both the Apple Silicon and the older Intel layouts.
public enum BatteryReader {

    /// Registry path of the node the whole battery stack hangs off.
    public static let rootServiceName = "AppleSmartBattery"

    public static func read() -> BatterySnapshot? {
        guard let tree = IORegistryTree.capture(serviceName: rootServiceName, depth: 4) else {
            return nil
        }
        var snapshot = makeSnapshot(from: tree)

        // Applied **after** the registry pass, deliberately.
        //
        // `makeSnapshot` fills `isCharging` / `externalConnected` from the AppleSmartBattery
        // registers, which the driver only republishes every 30–60 s. Merging IOPS before that
        // pass meant the live power-source state was immediately written over by the stale register
        // value, so unplugging took up to a minute to show. IOPS has to have the last word.
        let powerSource = PowerSourceReader.read()
        apply(powerSource, to: &snapshot)
        return snapshot
    }

    // MARK: - Pure transformation (kept separate so it can be exercised without hardware)

    public static func makeSnapshot(from tree: RegistryNode) -> BatterySnapshot {
        var snapshot = BatterySnapshot()
        snapshot.timestamp = Date()
        snapshot.registryTree = tree

        let top = tree.properties
        let topBatteryData = ValueCoercion.dictionary(top["BatteryData"]) ?? [:]
        let pack = tree.child(className: "AppleSmartBatteryPack")
        let packBatteryData = ValueCoercion.dictionary(pack?.properties["BatteryData"]) ?? [:]

        // Priority: the pack's gas-gauge data is the richest, then the battery node's own
        // BatteryData, then whatever scalars the node publishes at the top level.
        let p = LayeredProperties([packBatteryData, topBatteryData, top])

        // MARK: Identity
        snapshot.deviceName = p.firstString(["DeviceName"])
        snapshot.serial = p.firstString(["Serial", "BatterySerialNumber"])
        snapshot.manufacturerData = ManufacturerData.decode(p.data("MfgData") ?? p.data("ManufacturerData"))
        snapshot.manufactureDate = ManufactureDateDecoder.decode(p.uint64("ManufactureDate"))
        snapshot.hardwareRevision = snapshot.manufacturerData?.hardwareRevision
        snapshot.firmwareVersion = snapshot.manufacturerData?.firmwareVersion

        // MARK: Charge state
        snapshot.chargePercent = p.double("CurrentCapacity").map { Double($0) }
        snapshot.maxCapacityPercent = p.int("MaxCapacity")
        snapshot.stateOfChargePercent = p.double("StateOfCharge")
        snapshot.isCharging = p.bool("IsCharging") ?? false
        snapshot.fullyCharged = p.bool("FullyCharged") ?? false
        snapshot.externalConnected = p.bool("ExternalConnected")
            ?? p.bool("AppleRawExternalConnected") ?? false
        snapshot.externalChargeCapable = p.bool("ExternalChargeCapable") ?? false
        snapshot.atCriticalLevel = p.bool("AtCriticalLevel") ?? false
        snapshot.batteryInstalled = p.bool("BatteryInstalled") ?? true

        // MARK: Capacity in mAh
        snapshot.designCapacityMAh = p.firstInt(["DesignCapacity"])
        snapshot.maxCapacityMAh = p.firstInt(["AppleRawMaxCapacity", "FccComp1", "FccComp2", "FullChargeCapacity"])
        snapshot.nominalCapacityMAh = p.firstInt(["NominalChargeCapacity"])
        snapshot.currentCapacityMAh = p.firstInt(["AppleRawCurrentCapacity", "RemainingCapacity", "TrueRemainingCapacity"])
        snapshot.absoluteCapacityMAh = p.firstInt(["AbsoluteCapacity"])

        // MARK: Electrical
        if let millivolts = p.firstInt(["AppleRawBatteryVoltage", "Voltage"]) {
            snapshot.voltageVolts = Double(millivolts) / 1000
        }
        snapshot.amperageAmps = resolveAmperage(p, externalConnected: snapshot.externalConnected)
        if let centiCelsius = p.firstInt(["Temperature"]) {
            snapshot.temperatureCelsius = Double(centiCelsius) / 100
        }
        if let centiCelsius = p.firstInt(["VirtualTemperature"]) {
            snapshot.virtualTemperatureCelsius = Double(centiCelsius) / 100
        }

        // MARK: Cycles
        snapshot.cycleCount = p.firstInt(["CycleCount"])
        snapshot.designCycleCount = p.firstInt(["DesignCycleCount9C", "DesignCycleCount", "DesignCycleCount9c"])

        // MARK: Freshness
        // A Unix timestamp of the driver's last republish of this whole node.
        if let epoch = p.uint64("UpdateTime"), epoch > 0 {
            snapshot.registryUpdateTime = Date(timeIntervalSince1970: TimeInterval(epoch))
        }

        // MARK: Time estimates
        snapshot.gaugeTimeToEmptyMinutes = p.minutes("AvgTimeToEmpty")
        snapshot.gaugeTimeToFullMinutes = p.minutes("AvgTimeToFull")
        snapshot.rawTimeRemainingMinutes = p.minutes("TimeRemaining")

        // MARK: Diagnostics
        snapshot.permanentFailureStatus = p.firstInt(["PermanentFailureStatus"])
        snapshot.batteryHealthMetric = p.firstInt(["BatteryHealthMetric"])
        snapshot.faultType = p.firstInt(["FaultType"])
        snapshot.batteryCellDisconnectCount = p.firstInt(["BatteryCellDisconnectCount"])

        // MARK: Attached hardware
        snapshot.adapter = makeAdapter(from: top)
        snapshot.charger = makeCharger(from: tree, top: top)
        snapshot.telemetry = makeTelemetry(from: ValueCoercion.dictionary(top["PowerTelemetryData"]))
        snapshot.powerDistribution = makePowerDistribution(from: ValueCoercion.dictionary(top["PowerDistribution"]))
        snapshot.banks = makeBanks(from: pack)
        snapshot.lifetime = makeLifetime(from: ValueCoercion.dictionary(packBatteryData["LifetimeData"]))

        return snapshot
    }

    /// Merges the I/O Kit power-source view on top of the registry reading. The registry is
    /// preferred for capacity/electrical values; IOPS supplies presence, the live power-source
    /// state, and the system's own time estimate.
    public static func apply(_ powerSource: PowerSourceReading?, to snapshot: inout BatterySnapshot) {
        guard let powerSource else { return }
        if let present = powerSource.isPresent { snapshot.isPresent = present }

        // Whether a charger is attached is the one thing that must not lag.
        //
        // `ExternalConnected` and `IsCharging` live in the AppleSmartBattery node, which the driver
        // republishes only every 30–60 s — so trusting them left the menu bar bolt showing for up
        // to a minute after the cable was pulled. IOPS is updated by powerd the moment the source
        // changes, and our IOPS notification fires then too, so IOPS wins here. The registry value
        // is still the fallback when IOPS has nothing to say.
        if let state = powerSource.powerSourceState {
            snapshot.externalConnected = (state == "AC Power")
        }
        if let charging = powerSource.isCharging { snapshot.isCharging = charging }
        if let charged = powerSource.isCharged, charged { snapshot.fullyCharged = true }
        if snapshot.chargePercent == nil, let percent = powerSource.currentCapacityPercent {
            snapshot.chargePercent = Double(percent)
        }
        if snapshot.currentCapacityMAh == nil, let milliamps = powerSource.currentMA {
            snapshot.currentCapacityMAh = milliamps
        }
        if snapshot.voltageVolts == nil, let millivolts = powerSource.voltageMV {
            snapshot.voltageVolts = Double(millivolts) / 1000
        }
        if snapshot.designCycleCount == nil { snapshot.designCycleCount = powerSource.designCycleCount }
        if snapshot.serial == nil { snapshot.serial = powerSource.hardwareSerialNumber }
        if snapshot.gaugeTimeToEmptyMinutes == nil { snapshot.gaugeTimeToEmptyMinutes = powerSource.timeToEmptyMinutes }
        if snapshot.gaugeTimeToFullMinutes == nil { snapshot.gaugeTimeToFullMinutes = powerSource.timeToFullChargeMinutes }
        snapshot.systemTimeToEmptyMinutes = powerSource.isOnACPower ? nil : powerSource.systemTimeRemainingMinutes
        snapshot.systemTimeToFullMinutes = powerSource.isOnACPower && snapshot.isCharging
            ? powerSource.systemTimeRemainingMinutes : nil
    }

    // MARK: - Field builders

    /// Picks the best available current reading.
    ///
    /// `Amperage` is the gauge's smoothed value (the one macOS uses for its own estimates)
    /// while `InstantAmperage` is the instantaneous sample. We prefer the instantaneous
    /// value because this is a live monitor, but fall back when the gauge reports it as a
    /// hard zero while the smoothed value is clearly non-zero.
    private static func resolveAmperage(_ p: LayeredProperties, externalConnected: Bool) -> Double? {
        let instant = p.firstInt(["InstantAmperage"])
        let smoothed = p.firstInt(["Amperage"])
        var milliamps: Int?
        if let instant, instant != 0 {
            milliamps = instant
        } else if let smoothed {
            milliamps = smoothed
        } else {
            milliamps = instant
        }
        guard var value = milliamps else { return nil }

        // Defensive sign normalisation: a battery that is not connected to external power
        // cannot be charging, so a positive value in that state is a firmware sign flip.
        if !externalConnected, value > 0 { value = -value }
        return Double(value) / 1000
    }

    /// The adapter's identity keys (`Name`, `Manufacturer`, `SerialString`, `FwVersion`) come
    /// and go with the PD negotiation state — a live dump taken minutes apart had `Watts`,
    /// `Current` and `AdapterVoltage` but no `Name` at all. So `AdapterDetails` and the first
    /// element of `AppleRawAdapterDetails` are layered per key rather than treated as
    /// alternatives, and one dict missing a field no longer hides the other's value.
    private static func makeAdapter(from top: [String: Any]) -> AdapterSnapshot? {
        let rawDetails = ValueCoercion.array(top["AppleRawAdapterDetails"])?
            .compactMap { ValueCoercion.dictionary($0) }
            .first
        let layers = [
            ValueCoercion.dictionary(top["AdapterDetails"]) ?? [:],
            rawDetails ?? [:],
        ]
        guard layers.contains(where: { !$0.isEmpty }) else { return nil }
        let a = LayeredProperties(layers)

        var adapter = AdapterSnapshot()
        adapter.name = a.string("Name")
        adapter.manufacturer = a.string("Manufacturer")
        adapter.model = a.string("Model")
        adapter.serial = a.string("SerialString")
        adapter.firmwareVersion = a.string("FwVersion")
        adapter.hardwareVersion = a.string("HwVersion")
        adapter.descriptionText = a.string("Description")
        adapter.adapterID = a.int("AdapterID")
        adapter.familyCode = a.uint64("FamilyCode")
        adapter.powerTier = a.int("AdapterPowerTier")
        adapter.isWireless = a.bool("IsWireless")
        adapter.ratedWatts = a.double("Watts")

        if let millivolts = a.int("AdapterVoltage") { adapter.negotiatedVoltageVolts = Double(millivolts) / 1000 }
        if let milliamps = a.int("Current") { adapter.negotiatedCurrentAmps = Double(milliamps) / 1000 }
        if let v = adapter.negotiatedVoltageVolts, let i = adapter.negotiatedCurrentAmps {
            adapter.negotiatedWatts = v * i
        }

        if let menu = a.array("UsbHvcMenu") {
            adapter.contracts = menu.compactMap { entry in
                guard let d = ValueCoercion.dictionary(entry) else { return nil }
                let m = LayeredProperties([d])
                var contract = PDContract()
                contract.index = m.int("Index")
                if let mv = m.int("MaxVoltage") { contract.maxVoltageVolts = Double(mv) / 1000 }
                if let ma = m.int("MaxCurrent") { contract.maxCurrentAmps = Double(ma) / 1000 }
                return contract
            }
        }
        return adapter
    }

    private static func makeCharger(from tree: RegistryNode, top: [String: Any]) -> ChargerSnapshot? {
        // `AppleChargerData` is a child of `AppleSmartBattery`; its own `ChargerData`
        // dictionary is the charger's register dump.
        let dictionary = ValueCoercion.dictionary(tree.child(className: "AppleChargerData")?.properties["ChargerData"])
            ?? ValueCoercion.dictionary(top["ChargerData"])
        guard let d = dictionary, !d.isEmpty else { return nil }
        let c = LayeredProperties([d])

        var charger = ChargerSnapshot()
        charger.chargerID = c.int("ChargerID")
        if let mv = c.int("ChargingVoltage") { charger.chargingVoltageVolts = Double(mv) / 1000 }
        if let ma = c.int("ChargingCurrent") { charger.chargingCurrentAmps = Double(ma) / 1000 }
        if let mv = c.int("ChargerVBUS") { charger.vbusVolts = Double(mv) / 1000 }
        if let ma = c.int("ChargerIBUS") { charger.ibusAmps = Double(ma) / 1000 }
        if let mw = c.int("ChargerPower") { charger.chargerPowerWatts = Double(mw) / 1000 }
        charger.efficiency = c.double("ChargerEfficiency")
        charger.accumulatedEfficiency = c.double("ChargerAccumulatedEfficiency")
        charger.pmuConfiguration = c.int("PMUConfiguration")
        charger.pmuConfigured = c.int("PMUConfigured")
        charger.notChargingReason = c.uint64("NotChargingReason").map { UInt32(truncatingIfNeeded: $0) }
        charger.slowChargingReason = c.uint64("SlowChargingReason").map { UInt32(truncatingIfNeeded: $0) }
        charger.inhibitReason = c.uint64("ChargerInhibitReason").map { UInt32(truncatingIfNeeded: $0) }
        charger.hardwareILimitBackoffReason = c.uint64("ChargerHwIlimBackoffReason").map { UInt32(truncatingIfNeeded: $0) }
        charger.timeChargingThermallyLimitedSeconds = c.int("TimeChargingThermallyLimited")
        charger.resetCounter = c.int("ChargerResetCounter")
        return charger
    }

    private static func makeTelemetry(from d: [String: Any]?) -> PowerTelemetry? {
        guard let d, !d.isEmpty else { return nil }
        let t = LayeredProperties([d])
        var telemetry = PowerTelemetry()
        telemetry.systemPowerInMW = t.int("SystemPowerIn")
        telemetry.systemLoadMW = t.int("SystemLoad")
        telemetry.systemVoltageInMV = t.int("SystemVoltageIn")
        telemetry.systemCurrentInMA = t.int("SystemCurrentIn")
        telemetry.batteryPowerMW = t.int("BatteryPower")
        telemetry.adapterEfficiencyLossMW = t.int("AdapterEfficiencyLoss")
        telemetry.wallEnergyEstimateMW = t.int("WallEnergyEstimate")
        telemetry.systemEnergyConsumedMW = t.int("SystemEnergyConsumed")
        telemetry.powerTelemetryErrorCount = t.int("PowerTelemetryErrorCount")
        return telemetry
    }

    private static func makePowerDistribution(from d: [String: Any]?) -> PowerDistribution? {
        guard let d, !d.isEmpty else { return nil }
        let p = LayeredProperties([d])
        var distribution = PowerDistribution()
        distribution.inputPowerMW = p.int("IPDInputPower")
        distribution.inputCurrentMA = p.int("IPDInputCurrent")
        distribution.inputVoltageMV = p.int("IPDInputVoltage")
        distribution.wattageOverrideMW = p.int("IPDWattageOverride")
        distribution.chargingAllowed = p.bool("IPDChargingAllowed")
        distribution.ratio = p.int("IPDRatio")
        return distribution
    }

    private static func makeBanks(from pack: RegistryNode?) -> [BankSnapshot] {
        guard let pack else { return [] }
        return pack.children(className: "AppleSmartBatteryBank").map { bankNode in
            let d = ValueCoercion.dictionary(bankNode.properties["BatteryData"]) ?? [:]
            let b = LayeredProperties([d])
            var bank = BankSnapshot()
            bank.bankID = ValueCoercion.int(bankNode.properties["BankID"])
            bank.packID = ValueCoercion.int(bankNode.properties["PackID"])
            if let mv = b.int("CellVoltage") { bank.cellVoltageVolts = Double(mv) / 1000 }
            bank.qmaxMAh = b.int("Qmax")
            bank.weightedRa = b.double("WeightedRa")
            bank.presentDOD = b.int("PresentDOD")
            bank.dod0 = b.int("DOD0")
            bank.cellCurrentAmps = bankNode.children(className: "AppleSmartBatteryCell").compactMap { cellNode in
                guard let cellData = ValueCoercion.dictionary(cellNode.properties["CellData"]),
                      let ma = ValueCoercion.int(cellData["CellCurrent"]) else { return nil }
                return Double(ma) / 1000
            }
            return bank
        }
        .sorted { ($0.bankID ?? 0) < ($1.bankID ?? 0) }
    }

    /// Lifetime temperature records do **not** use the same scale as the live `Temperature`
    /// key. In the gauge's flash block the average is stored in tenths of a degree while the
    /// min/max are whole degrees: a real dump reads `{average: 224, min: 9, max: 46}`, which
    /// can only mean 22.4 °C / 9 °C / 46 °C. Any value above 100 °C is physically impossible
    /// for a battery, so it is unambiguously a scaled value.
    private static func lifetimeCelsius(_ raw: Int?) -> Double? {
        guard let raw else { return nil }
        return raw > 100 ? Double(raw) / 10 : Double(raw)
    }

    private static func makeLifetime(from d: [String: Any]?) -> LifetimeStats? {
        guard let d, !d.isEmpty else { return nil }
        let l = LayeredProperties([d])
        var stats = LifetimeStats()
        stats.totalOperatingTimeMinutes = l.int("TotalOperatingTime")
        stats.cycleCountLastQmax = l.int("CycleCountLastQmax")
        stats.temperatureSampleCount = l.int("TemperatureSamples")
        stats.averageTemperatureCelsius = Self.lifetimeCelsius(l.int("AverageTemperature"))
        stats.minimumTemperatureCelsius = Self.lifetimeCelsius(l.int("MinimumTemperature"))
        stats.maximumTemperatureCelsius = Self.lifetimeCelsius(l.int("MaximumTemperature"))
        if let mv = l.int("MinimumPackVoltage") { stats.minimumPackVoltageVolts = Double(mv) / 1000 }
        if let mv = l.int("MaximumPackVoltage") { stats.maximumPackVoltageVolts = Double(mv) / 1000 }
        if let ma = l.uint64("MaximumChargeCurrent") { stats.maximumChargeCurrentAmps = Double(Int64(bitPattern: ma)) / 1000 }
        if let ma = l.uint64("MaximumDischargeCurrent") { stats.maximumDischargeCurrentAmps = Double(Int64(bitPattern: ma)) / 1000 }
        stats.rdisCount = l.int("RDISCnt")
        return stats
    }
}

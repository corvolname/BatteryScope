import Foundation

/// One live read of the SMC's power/thermal keys.
///
/// Every field here is a **direct measurement in real units** — watts and degrees — read straight
/// from an SMC key. Nothing is derived, and nothing needs calibrating.
public struct SMCPowerReading {
    /// `PSTR` — total system power draw, watts.
    public var systemWatts: Double?
    /// `PDTR` — power delivered by the adapter / DC-in, watts.
    public var adapterWatts: Double?
    /// Battery power in watts, **computed** from `B0AC` × `B0AV`, sign included.
    ///
    /// `B0AC` is a signed current in mA and `B0AV` a voltage in mV, so their product is watts with
    /// the direction already in it. This replaces `PPBR`, which turned out not to be battery power
    /// at all (see `SMCPowerReader.batteryCurrentKey`).
    public var batteryWatts: Double?
    /// `B0AC` in **amps**, sign included (negative = discharging). The chart wants this on its own
    /// because current is what actually swings second to second as the load moves.
    public var batteryCurrentAmps: Double?
    /// `TB0T` — battery temperature, °C.
    public var batteryTemperatureCelsius: Double?
    /// `F0Ac` — fan speed, rpm.
    public var fanRPM: Double?
    public var timestamp = Date()
    /// Keys that answered, so the UI can be honest about what this machine actually exposes.
    public var resolvedKeys: [String] = []

    public init() {}

    public init(systemWatts: Double? = nil,
                adapterWatts: Double? = nil,
                batteryWatts: Double? = nil,
                batteryTemperatureCelsius: Double? = nil,
                fanRPM: Double? = nil) {
        self.systemWatts = systemWatts
        self.adapterWatts = adapterWatts
        self.batteryWatts = batteryWatts
        self.batteryTemperatureCelsius = batteryTemperatureCelsius
        self.fanRPM = fanRPM
    }

    public var isEmpty: Bool { resolvedKeys.isEmpty }
}

/// Samples the SMC power keys.
///
/// Measured cadence on a MacBookPro18,2: the keys below each produce a new value about **once per
/// second** — sampled every second, `PSTR` moved 21.91 → 21.54 → 24.71 → 21.82 and `B0AC` moved
/// −1725 → −1979 → −1745 mA. That is the whole reason for reading the SMC rather than the
/// `AppleSmartBattery` node: the node's telemetry holds still for tens of seconds, so a card built
/// on it looks frozen next to a readout that polls the SMC.
public final class SMCPowerReader {

    public static let systemKey = "PSTR"
    public static let adapterKey = "PDTR"
    /// Battery **current**, mA, signed: negative while discharging.
    public static let batteryCurrentKey = "B0AC"
    /// Battery **voltage**, mV.
    public static let batteryVoltageKey = "B0AV"
    public static let batteryTemperatureKey = "TB0T"
    public static let fanKey = "F0Ac"

    /// Not used, kept named so the reason it is not used is discoverable.
    ///
    /// `PPBR` reads about a quarter of the true battery power while charging (1.71 W where the
    /// battery was taking 7.16 W) and moves *opposite* to it. `B0AC × B0AV` agrees with the node's
    /// `PowerTelemetryData.BatteryPower` and with `V × A`, so that is what `batteryWatts` holds.
    public static let misleadingBatteryPowerKey = "PPBR"

    private let client: SMCClient
    /// Only the keys this machine actually has, resolved once.
    private let available: Set<String>

    public init?(client: SMCClient? = nil) {
        guard let client = client ?? SMCClient() else { return nil }
        self.client = client
        var available: Set<String> = []
        for key in [Self.systemKey, Self.adapterKey, Self.batteryCurrentKey,
                    Self.batteryVoltageKey, Self.batteryTemperatureKey, Self.fanKey]
        where client.hasKey(key) {
            available.insert(key)
        }
        // Without at least one power reading there is nothing this reader adds.
        guard available.contains(Self.systemKey)
                || available.contains(Self.adapterKey)
                || (available.contains(Self.batteryCurrentKey)
                    && available.contains(Self.batteryVoltageKey)) else { return nil }
        self.available = available
    }

    public var availableKeys: [String] { available.sorted() }

    public func read() -> SMCPowerReading {
        var reading = SMCPowerReading()
        for key in available.sorted() {
            // The battery pair are integers (si16 mA, ui16 mV); everything else is a float.
            let value: Double?
            if key == Self.batteryCurrentKey || key == Self.batteryVoltageKey {
                value = client.readInt(key).map(Double.init)
            } else {
                value = client.readDouble(key)
            }
            guard let value else { continue }
            reading.resolvedKeys.append(key)
            // A nonsense float from a mis-decoded key is worse than no value.
            guard value.isFinite, abs(value) < 100_000 else {
                reading.resolvedKeys.removeLast()
                continue
            }
            switch key {
            case Self.systemKey: reading.systemWatts = value
            case Self.adapterKey: reading.adapterWatts = value
            case Self.batteryTemperatureKey: reading.batteryTemperatureCelsius = value
            case Self.fanKey: reading.fanRPM = value
            default: break
            }
        }
        // mA × mV / 1e6 = W, sign included — negative is discharge.
        if let current = client.readInt(Self.batteryCurrentKey), available.contains(Self.batteryCurrentKey),
           let millivolts = client.readInt(Self.batteryVoltageKey), available.contains(Self.batteryVoltageKey) {
            let watts = Double(current) * Double(millivolts) / 1_000_000
            if watts.isFinite, abs(watts) < 100_000 { reading.batteryWatts = watts }
            reading.batteryCurrentAmps = Double(current) / 1000
        }
        return reading
    }
}

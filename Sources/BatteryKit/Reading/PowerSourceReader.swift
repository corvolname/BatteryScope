import Foundation
import IOKit.ps

/// The I/O Kit power-source view of the battery (`IOPSCopyPowerSourcesInfo`).
///
/// This is the same API the system menu-bar battery indicator uses. It is coarser than the
/// raw `AppleSmartBattery` registry node — no capacity in mAh, no temperature — but it is
/// the authoritative source for "is the battery present", "what does the system think the
/// remaining time is", and the power-source state transitions we watch for plug/unplug.
public struct PowerSourceReading {
    public init() {}

    public var name: String?
    public var type: String?
    public var transportType: String?
    public var powerSourceState: String?
    public var isPresent: Bool?
    public var isCharging: Bool?
    public var isCharged: Bool?
    public var currentCapacityPercent: Int?
    public var maxCapacityPercent: Int?
    public var currentMA: Int?
    public var voltageMV: Int?
    public var timeToEmptyMinutes: Int?
    public var timeToFullChargeMinutes: Int?
    public var designCycleCount: Int?
    public var hardwareSerialNumber: String?
    public var lowPowerModeActive: Bool?
    public var batteryProvidesTimeRemaining: Bool?
    /// System-wide estimate from `IOPSGetTimeRemainingEstimate()`, in minutes.
    public var systemTimeRemainingMinutes: Int?

    public var isOnACPower: Bool { powerSourceState == "AC Power" }
}

public enum PowerSourceReader {

    /// Minutes value `IOPS` uses for "not applicable".
    private static let unlimited: Double = -2.0
    private static let unknown: Double = -1.0

    public static func read() -> PowerSourceReading? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [AnyObject],
              !list.isEmpty else {
            return nil
        }

        var fallback: PowerSourceReading?
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any]
            else { continue }

            let reading = makeReading(from: description)
            // Prefer the internal battery; remember any other source as a fallback.
            if reading.type == kIOPSInternalBatteryType || description["Type"] as? String == "InternalBattery" {
                return attachSystemEstimate(to: reading)
            }
            if fallback == nil { fallback = reading }
        }
        return fallback.map(attachSystemEstimate)
    }

    private static func makeReading(from d: [String: Any]) -> PowerSourceReading {
        func value(_ standardized: String, _ literal: String) -> Any? {
            d[standardized] ?? d[literal]
        }
        var reading = PowerSourceReading()
        reading.name = ValueCoercion.string(value(kIOPSNameKey, "Name"))
        reading.type = ValueCoercion.string(value(kIOPSTypeKey, "Type"))
        reading.transportType = ValueCoercion.string(value(kIOPSTransportTypeKey, "Transport Type"))
        reading.powerSourceState = ValueCoercion.string(value(kIOPSPowerSourceStateKey, "Power Source State"))
        reading.isPresent = ValueCoercion.bool(value(kIOPSIsPresentKey, "Is Present"))
        reading.isCharging = ValueCoercion.bool(value(kIOPSIsChargingKey, "Is Charging"))
        reading.isCharged = ValueCoercion.bool(value(kIOPSIsChargedKey, "Is Charged"))
        reading.currentCapacityPercent = ValueCoercion.int(value(kIOPSCurrentCapacityKey, "Current Capacity"))
        reading.maxCapacityPercent = ValueCoercion.int(value(kIOPSMaxCapacityKey, "Max Capacity"))
        reading.currentMA = ValueCoercion.int(value(kIOPSCurrentKey, "Current"))
        reading.voltageMV = ValueCoercion.int(value(kIOPSVoltageKey, "Voltage"))
        reading.timeToEmptyMinutes = normalizeMinutes(ValueCoercion.int(value(kIOPSTimeToEmptyKey, "Time to Empty")))
        reading.timeToFullChargeMinutes = normalizeMinutes(ValueCoercion.int(value(kIOPSTimeToFullChargeKey, "Time to Full Charge")))
        reading.designCycleCount = ValueCoercion.int(d["DesignCycleCount"])
        reading.hardwareSerialNumber = ValueCoercion.string(value(kIOPSHardwareSerialNumberKey, "Hardware Serial Number"))
        reading.lowPowerModeActive = ValueCoercion.bool(d["LPM Active"])
        reading.batteryProvidesTimeRemaining = ValueCoercion.bool(d["Battery Provides Time Remaining"])
        return reading
    }

    /// IOPS signals "not applicable" with 0, or leaves stale sentinel values behind.
    private static func normalizeMinutes(_ value: Int?) -> Int? {
        guard let value, value > 0, value != 65535 else { return nil }
        return value
    }

    private static func attachSystemEstimate(to reading: PowerSourceReading) -> PowerSourceReading {
        var copy = reading
        let seconds = IOPSGetTimeRemainingEstimate()
        if seconds != unlimited, seconds != unknown, seconds > 0 {
            copy.systemTimeRemainingMinutes = Int((seconds / 60).rounded())
        }
        return copy
    }
}

/// Watches for power-source changes (plug/unplug, charge start/stop).
///
/// A run-loop source is far more responsive than polling: macOS posts the notification the
/// moment the adapter state changes, so the menu bar updates instantly even if the regular
/// sampling interval is set to something lazy like 5 seconds.
public final class PowerSourceWatcher {

    private var runLoopSource: CFRunLoopSource?
    private let handler: () -> Void

    public init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    public func start() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let watcher = Unmanaged<PowerSourceWatcher>.fromOpaque(context).takeUnretainedValue()
            watcher.handler()
        }, context)?.takeRetainedValue() else { return }

        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    public func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        }
        runLoopSource = nil
    }

    deinit { stop() }
}

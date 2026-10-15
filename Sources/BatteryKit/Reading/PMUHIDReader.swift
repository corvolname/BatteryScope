import Foundation
import IOKit

/// One PMIC rail reading. `kind` comes from the event's own type field: the PMU reports
/// `1` for a current rail and `2` for a voltage rail.
public struct PMURail: Hashable {
    public enum Kind: String {
        case current
        case voltage
        case unknown
    }
    public var kind: Kind
    public var rawValue: Double
    public var channel: String
}

/// A live read of the SoC's PMU sensors.
public struct PMUTelemetry {
    public var timestamp = Date()
    /// Channel name → degrees Celsius. Units are certain: the event carries °C directly.
    public var temperatures: [String: Double] = [:]
    /// Channel name → rail reading. Values are live but the engineering unit is not documented.
    public var rails: [String: PMURail] = [:]

    /// Channels that are not temperature sensors.
    ///
    /// `tcal` reads a **constant 51.85 °C across every sample** while all the real sensors sit in
    /// the 30–37 °C band and move every second. It is a calibration reference, not a measurement.
    /// Including it meant "the hottest sensor" always resolved to this fixed value, so the card
    /// reported 51.9 °C — about 15 °C above anything the chip was actually at — and the chart
    /// drew a perfectly flat line.
    public static let calibrationChannels: Set<String> = ["tcal"]

    /// Real sensor readings only.
    public var sensorTemperatures: [String: Double] {
        temperatures.filter { !Self.calibrationChannels.contains($0.key) }
    }

    /// Hottest *sensor*, in °C.
    public var hottest: (channel: String, celsius: Double)? {
        sensorTemperatures.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    public var averageTemperatureCelsius: Double? {
        let sensors = sensorTemperatures
        guard !sensors.isEmpty else { return nil }
        return sensors.values.reduce(0, +) / Double(sensors.count)
    }

    /// Hottest and coolest sensor, for showing the spread across the die.
    public var temperatureRange: (lowest: Double, highest: Double)? {
        let sensors = sensorTemperatures
        guard let lowest = sensors.values.min(), let highest = sensors.values.max() else { return nil }
        return (lowest, highest)
    }
}

/// Reads the PMU's HID event services.
///
/// ## Why this exists
///
/// `AppleSmartBattery` — the node almost every battery app reads — republishes its whole
/// property set only about once every 60 seconds (verified three ways; see the README). That
/// makes battery percentage, capacity and `SystemPowerIn` inherently slow.
///
/// The SoC's PMU sensors are a **separate, much faster path**: they are `IOHIDEventService`
/// objects (`Product = "PMU …"`, Apple vendor usage page `0xFF08`) whose values are delivered as
/// HID events. Measured on a MacBookPro18,2, **68 of 80 rail channels changed within 5.5 s**,
/// several of them 15 times in 11 samples — i.e. sub-second. The temperature channels are
/// equally live.
///
/// This is the only public path to per-sensor die temperatures; the alternative families
/// (IOReport, IOPS, raw SMC keys) do not expose them on Apple Silicon.
///
/// ## Units
///
/// Temperature events carry degrees Celsius on field offset 0, and those values are verified
/// (44–52 °C across the die sensors, rising under load). Rail events carry their value on offset
/// 0 and a quantity type on offset 1, but the *scale* differs per channel — `vldo4` reads `3.30`
/// (volts) while `vbuck1` reads `16206` — so this type deliberately exposes rails as
/// `rawValue` rather than pretending to know watts. Only temperatures are surfaced in the UI.
public final class PMUHIDReader {

    // Private, undocumented IOKit symbols; resolved dynamically because there are no headers.
    private typealias CreateWithType = @convention(c) (CFAllocator?, Int32, CFDictionary?) -> UnsafeMutableRawPointer?
    private typealias CopyServices = @convention(c) (UnsafeMutableRawPointer?) -> Unmanaged<CFArray>?
    private typealias ServiceCopyProperty = @convention(c) (UnsafeMutableRawPointer?, CFString?) -> Unmanaged<CFTypeRef>?
    private typealias ServiceCopyEvent = @convention(c) (UnsafeMutableRawPointer?, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias EventGetFloat = @convention(c) (CFTypeRef?, UInt32) -> Double
    private typealias EventGetType = @convention(c) (CFTypeRef?) -> Int32

    /// `kIOHIDEventSystemClientTypeMonitor`
    private static let clientTypeMonitor: Int32 = 1
    /// `kIOHIDEventTypeTemperature`
    private static let eventTypeTemperature: Int64 = 15
    /// `kIOHIDEventTypePower`
    private static let eventTypePower: Int64 = 25
    /// Field base is `type << 16`; the payload sits on offset 0, the quantity type on offset 1.
    private static let powerQuantityOffset: UInt32 = 1

    private let client: UnsafeMutableRawPointer
    private var services: [AnyObject] = []
    private let copyProperty: ServiceCopyProperty
    private let copyEvent: ServiceCopyEvent
    private let getFloat: EventGetFloat
    private let getEventType: EventGetType

    /// Returns `nil` when the private HID path is unavailable, so callers can degrade quietly.
    public init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else {
            return nil
        }
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let create = symbol("IOHIDEventSystemClientCreateWithType", CreateWithType.self),
              let copyServices = symbol("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyProperty = symbol("IOHIDServiceClientCopyProperty", ServiceCopyProperty.self),
              let copyEvent = symbol("IOHIDServiceClientCopyEvent", ServiceCopyEvent.self),
              let getFloat = symbol("IOHIDEventGetFloatValue", EventGetFloat.self),
              let getEventType = symbol("IOHIDEventGetType", EventGetType.self),
              let client = create(kCFAllocatorDefault, Self.clientTypeMonitor, nil),
              let list = copyServices(client)?.takeRetainedValue() as? [AnyObject] else {
            return nil
        }
        self.client = client
        self.copyProperty = copyProperty
        self.copyEvent = copyEvent
        self.getFloat = getFloat
        self.getEventType = getEventType

        // The service list is stable; only the event payloads change.
        self.services = list.filter { property($0, "Product").hasPrefix("PMU ") }
        guard !services.isEmpty else { return nil }
    }

    public var channelCount: Int { services.count }

    public func read() -> PMUTelemetry {
        var telemetry = PMUTelemetry()
        for service in services {
            let product = property(service, "Product")
            let channel = product.hasPrefix("PMU ") ? String(product.dropFirst(4)) : product

            if let event = event(for: service, type: Self.eventTypeTemperature),
               getEventType(event) == Int32(Self.eventTypeTemperature) {
                telemetry.temperatures[channel] = getFloat(event, UInt32(Self.eventTypeTemperature) << 16)
            }

            if let event = event(for: service, type: Self.eventTypePower),
               getEventType(event) == Int32(Self.eventTypePower) {
                let base = UInt32(Self.eventTypePower) << 16
                let value = getFloat(event, base)
                let quantity = getFloat(event, base | Self.powerQuantityOffset)
                let kind: PMURail.Kind
                switch Int(quantity.rounded()) {
                case 1: kind = .current
                case 2: kind = .voltage
                default: kind = .unknown
                }
                telemetry.rails[channel] = PMURail(kind: kind, rawValue: value, channel: channel)
            }
        }
        return telemetry
    }

    // MARK: - Helpers

    private func event(for service: AnyObject, type: Int64) -> CFTypeRef? {
        copyEvent(pointer(service), type, 0, 0)?.takeRetainedValue()
    }

    private func property(_ service: AnyObject, _ key: String) -> String {
        (copyProperty(pointer(service), key as CFString)?.takeRetainedValue()).map { "\($0)" } ?? ""
    }

    private func pointer(_ service: AnyObject) -> UnsafeMutableRawPointer {
        Unmanaged.passUnretained(service).toOpaque()
    }
}

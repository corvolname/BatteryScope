import Foundation
import IOKit

/// Watches the battery service for the driver's *own* notification that its properties changed.
///
/// Measured on a MacBookPro18,2 running macOS 27, `AppleSmartBattery` republishes its entire
/// property set only about once every 60 seconds — confirmed three independent ways:
///
/// * polling `UpdateTime` (a Unix timestamp of the republish) and watching it advance by 27–60 s;
/// * observing that every value (voltage, amperage, temperature, cell voltages, `SystemPowerIn`,
///   `SystemLoad`, even `InstantAmperage`) changes together at that one moment;
/// * registering `kIOGeneralInterest` and letting the driver push: over 60 seconds it fired
///   exactly once.
///
/// Polling therefore cannot make the data fresher, but it *can* be late by up to one polling
/// interval. This watcher removes that lateness: the moment the driver publishes, the app is told
/// and re-reads. The timer stays as a safety net (and to keep time-based estimates moving).
public final class BatteryRegistryWatcher {

    private let serviceName: String
    private let handler: () -> Void

    private var notificationPort: IONotificationPortRef?
    private var iterator: io_iterator_t = 0
    private var runLoopSource: CFRunLoopSource?
    private var isRunning = false

    public init(serviceName: String = BatteryReader.rootServiceName, handler: @escaping () -> Void) {
        self.serviceName = serviceName
        self.handler = handler
    }

    deinit { stop() }

    /// - Returns: `true` when the notification was registered successfully.
    @discardableResult
    public func start() -> Bool {
        guard !isRunning else { return true }

        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(serviceName))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }

        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }
        notificationPort = port

        if let source = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceInterestCallback = { refCon, _, _, _ in
            guard let refCon else { return }
            Unmanaged<BatteryRegistryWatcher>.fromOpaque(refCon).takeUnretainedValue().handler()
        }

        let result = IOServiceAddInterestNotification(port, service, kIOGeneralInterest,
                                                      callback, context, &iterator)
        guard result == KERN_SUCCESS else {
            stop()
            return false
        }
        isRunning = true
        return true
    }

    public func stop() {
        if iterator != 0 {
            IOObjectRelease(iterator)
            iterator = 0
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
            self.runLoopSource = nil
        }
        if let notificationPort {
            IONotificationPortDestroy(notificationPort)
            self.notificationPort = nil
        }
        isRunning = false
    }

    public var isWatching: Bool { isRunning }
}

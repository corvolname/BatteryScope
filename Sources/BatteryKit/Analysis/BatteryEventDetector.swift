import Foundation

/// Detects the transitions that are worth interrupting someone for.
///
/// Pure logic over two snapshots, deliberately kept in `BatteryKit` (rather than next to the
/// notification code) so it can be reasoned about and tested without any notification machinery.
public struct BatteryEventDetector {

    public struct Events {
        /// Set to the new connection state when the power source changed.
        public var powerSourceChanged: Bool?
        public var becameFullyCharged = false
        /// Set to the charge level when it fell through the low-battery threshold.
        public var crossedLowBatteryThreshold: Double?
        /// Set to the charge level when it rose through the user's charge ceiling.

        public init() {}
    }

    public init() {}

    /// - Note: a charge ceiling is deliberately not modelled here. macOS exposes no third-party
    ///   charge-control API on Apple Silicon (see README), so there is no feature to drive.
    ///   edge-triggered, so a battery that sits above its limit notifies once on the way up
    ///   rather than on every sample — and again after an unplug/replug cycle.
    public static func detect(previous: BatterySnapshot?,
                              current: BatterySnapshot?,
                              lowBatteryThreshold: Double,
) -> Events {
        var events = Events()
        guard let current else { return events }

        if let previous, previous.externalConnected != current.externalConnected {
            events.powerSourceChanged = current.externalConnected
        }
        if let previous, !previous.fullyCharged, current.fullyCharged {
            events.becameFullyCharged = true
        }
        if !current.externalConnected, let percent = current.chargePercent,
           percent <= lowBatteryThreshold {
            let previouslyAbove = (previous?.chargePercent ?? 101) > lowBatteryThreshold
            let wasOnAC = previous?.externalConnected ?? false
            if previouslyAbove || wasOnAC, percent > 0 {
                events.crossedLowBatteryThreshold = percent
            }
        }
        return events
    }
}

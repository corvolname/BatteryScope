import Foundation

/// An estimate produced from the sample history rather than from a single reading.
///
/// This exists because the hardware's own estimates are frequently useless: on the dev
/// machine `AvgTimeToEmpty`, `AvgTimeToFull` and `TimeRemaining` all read `65535`
/// ("unknown") while macOS reports "not charging". Measuring the actual capacity slope over
/// a few minutes gives a real answer instead.
public struct TrendEstimate {
    /// Signed capacity rate in mAh per hour: positive while charging.
    public var capacityRateMAhPerHour: Double?
    /// Signed power implied by the capacity rate.
    public var impliedPowerWatts: Double?
    public var minutesToEmpty: Int?
    public var minutesToFull: Int?
    public var windowSeconds: Double = 0
    public var sampleCount: Int = 0
    public var isReliable: Bool = false

    public var description: String {
        guard isReliable else { return "样本不足" }
        if let minutes = minutesToFull, minutes > 0 { return "预计 \(UnitFormat.minutes(minutes))后充满" }
        if let minutes = minutesToEmpty, minutes > 0 { return "预计可再用 \(UnitFormat.minutes(minutes))" }
        return "变化过小"
    }
}

public enum TrendEstimator {

    /// Smallest slope worth reporting, in mAh per hour. Below this the battery is
    /// effectively idle and any projection would be noise amplified into a fake ETA.
    public static let minimumSlopeMAhPerHour = 40.0

    public static func estimate(from samples: [BatterySample],
                                window: TimeInterval = 300,
                                now: Date = Date()) -> TrendEstimate {
        var result = TrendEstimate()
        let cutoff = now.addingTimeInterval(-window)
        let windowed = samples.filter { $0.timestamp >= cutoff }

        let points: [(t: Double, y: Double)] = windowed.compactMap { sample in
            guard let capacity = sample.currentCapacityMAh else { return nil }
            return (sample.timestamp.timeIntervalSince1970, capacity)
        }
        result.sampleCount = points.count

        guard points.count >= 8 else { return result }
        let span = (points.last?.t ?? 0) - (points.first?.t ?? 0)
        result.windowSeconds = span
        guard span >= 60 else { return result }

        guard let slopePerSecond = leastSquaresSlope(points) else { return result }
        let slopePerHour = slopePerSecond * 3600
        result.capacityRateMAhPerHour = slopePerHour

        let reference = windowed.last
        let voltage = reference?.voltage ?? windowed.compactMap(\.voltage).last
        if let voltage, let rate = result.capacityRateMAhPerHour {
            result.impliedPowerWatts = rate / 1000 * voltage
        }

        guard abs(slopePerHour) >= minimumSlopeMAhPerHour else { return result }

        let isCharging = reference?.isCharging ?? false
        let current = points.last?.y ?? 0
        let full = reference?.maxCapacityMAh ?? windowed.compactMap(\.maxCapacityMAh).last

        if slopePerHour > 0, isCharging, let full, full > current {
            let hours = (full - current) / slopePerHour
            if hours > 0, hours < 24 { result.minutesToFull = Int((hours * 60).rounded()) }
        } else if slopePerHour < 0, current > 0 {
            let hours = current / -slopePerHour
            if hours > 0, hours < 48 { result.minutesToEmpty = Int((hours * 60).rounded()) }
        }

        result.isReliable = result.minutesToEmpty != nil || result.minutesToFull != nil
        return result
    }

    /// Ordinary least squares slope of y over t, in units of y per second.
    public static func leastSquaresSlope(_ points: [(t: Double, y: Double)]) -> Double? {
        guard points.count >= 2 else { return nil }
        let n = Double(points.count)
        let meanT = points.reduce(0) { $0 + $1.t } / n
        let meanY = points.reduce(0) { $0 + $1.y } / n
        var covariance = 0.0
        var variance = 0.0
        for point in points {
            let dt = point.t - meanT
            covariance += dt * (point.y - meanY)
            variance += dt * dt
        }
        guard variance > 0 else { return nil }
        return covariance / variance
    }
}

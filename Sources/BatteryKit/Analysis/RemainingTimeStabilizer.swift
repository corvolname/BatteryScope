import Foundation

/// Smooths a remaining-time estimate so it reads like a prediction instead of a live reading.
///
/// The raw numbers are genuinely jumpy: a remaining-time estimate is `charge ÷ current`, so a few
/// seconds of compile load can turn "10h 20m" into "3h 05m" and back. macOS presents these values
/// at a much coarser cadence for exactly this reason.
///
/// Three things are done here:
///
/// * **Median over five minutes.** A median ignores the spikes entirely, where a mean would chase
///   them. This is the part that stops the wild swings.
/// * **Republish at most once a minute.** The estimate is a slow-moving idea; updating it every
///   second only makes it look unstable.
/// * **Round to five minutes.** So the digits do not twitch while the underlying value is
///   essentially unchanged.
public struct RemainingTimeStabilizer {

    /// Raw estimates kept for the median filter. At the default 1 s cadence this is five minutes.
    public var windowSize: Int = 301
    /// Minimum time between published changes.
    public var minimumInterval: TimeInterval = 60
    /// Published values are rounded to this many minutes.
    public var roundingMinutes: Int = 5
    /// Never publish a shorter estimate than this.
    public var minimumMinutes: Int = 5

    private var history: [Int] = []
    private var published: Int?
    private var lastPublishedAt = Date.distantPast

    public init() {}

    /// Feed the raw estimate (or `nil` when it is not applicable right now, e.g. a time-to-empty
    /// while charging). Returns the value that should be displayed.
    public mutating func update(raw: Int?, now: Date = Date()) -> Int? {
        if let raw, raw > 0 {
            history.append(raw)
            if history.count > windowSize { history.removeFirst(history.count - windowSize) }
        }
        guard let median = Self.median(history) else { return published }
        // Publish the first value immediately, then hold it until the interval has passed.
        guard published == nil || now.timeIntervalSince(lastPublishedAt) >= minimumInterval else {
            return published
        }
        published = Self.round(median, to: roundingMinutes, minimum: minimumMinutes)
        lastPublishedAt = now
        return published
    }

    /// Discards accumulated history, e.g. when the charging direction flips.
    public mutating func reset() {
        history.removeAll()
        published = nil
        lastPublishedAt = .distantPast
    }

    public static func median(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    public static func round(_ minutes: Int, to step: Int, minimum: Int) -> Int {
        guard step > 1 else { return Swift.max(minimum, minutes) }
        let rounded = Int((Double(minutes) / Double(step)).rounded()) * step
        return Swift.max(minimum, rounded)
    }
}

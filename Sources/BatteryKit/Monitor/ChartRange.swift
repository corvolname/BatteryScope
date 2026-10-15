import Foundation

/// Time windows offered by the live-charts picker.
///
/// Lives in BatteryKit rather than the view because it encodes two decisions that deserve tests:
/// how far back each window reaches, and — via `usesArchive` — whether a window can be served from
/// memory (samples are kept in RAM for 6 小时) or has to come off disk (one point per minute for
/// 30 天).
public enum ChartRange: String, CaseIterable, Identifiable {
    case fiveMinutes
    case fifteenMinutes
    case oneHour
    case session
    case day
    case week
    case archive

    /// What the picker offers. Three, not five.
    ///
    /// Five buttons spanning "5 minutes" to "30 day archive" is a range no ordinary reader wants to
    /// weigh up before looking at a chart. The three kept cover the questions actually asked —
    /// what just happened, what the last hour looked like, what this session has done.
    /// `fifteenMinutes` and `archive` still exist and still record; they are simply not offered
    /// here, and the archive remains available to the text report.
    public static var offered: [ChartRange] { [.fiveMinutes, .oneHour, .session, .day, .week, .archive] }

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fiveMinutes: return "5 分钟"
        case .fifteenMinutes: return "15 分钟"
        case .oneHour: return "1 小时"
        case .session: return "本次会话"
        case .day: return "24 小时"
        case .week: return "7 天"
        case .archive: return "30 天"
        }
    }

    /// Plain-language description of the window, used in the caption instead of a sample count.
    public var caption: String {
        switch self {
        case .fiveMinutes: return "最近 5 分钟"
        case .fifteenMinutes: return "最近 15 分钟"
        case .oneHour: return "最近 1 小时"
        case .session: return "本次运行以来"
        case .day: return "最近 24 小时"
        case .week: return "最近 7 天"
        case .archive: return "最近 30 天"
        }
    }

    public var duration: TimeInterval? {
        switch self {
        case .fiveMinutes: return 5 * 60
        case .fifteenMinutes: return 15 * 60
        case .oneHour: return 60 * 60
        case .session: return nil
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        case .archive: return 30 * 24 * 3600
        }
    }

    /// True when the range reaches further back than live memory holds.
    ///
    /// Kept only for the caption; which store a chart actually reads is decided per request in
    /// `sourceSamples`, by comparing the cutoff against the oldest live sample.
    public var usesArchive: Bool {
        guard let duration else { return false }
        return duration > 6 * 3600
    }
}

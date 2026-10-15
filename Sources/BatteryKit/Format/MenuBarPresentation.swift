import Foundation

/// Formatting for the menu bar item, kept out of the AppKit layer so it can be tested.
public enum MenuBarPresentation {

    /// Remaining time in the menu bar's own style: `4h 30m`, `45m`, `2h`.
    ///
    /// Hours and minutes spelled out rather than decimal hours, because `4.5H` reads as a
    /// different kind of number than a duration.
    public static func compactTime(_ minutes: Int?) -> String? {
        guard let minutes, minutes > 0 else { return nil }
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder)m" }
        if remainder == 0 { return "\(hours)h" }
        return "\(hours)h \(remainder)m"
    }

    /// The percentage as it is drawn *inside* the glyph.
    public static func percentText(_ percent: Double?) -> String? {
        guard let percent else { return nil }
        return String(format: "%.0f%%", percent)
    }

    /// What the menu bar item draws, given the power source and the two switches.
    public struct MenuBarReadings: Equatable {
        /// Drawn inside the battery outline, next to the bolt when there is one.
        public var iconText: String?
        /// Drawn after the icon.
        public var trailingText: String?

        public init(iconText: String? = nil, trailingText: String? = nil) {
            self.iconText = iconText
            self.trailingText = trailingText
        }
    }

    /// While external power is attached the outline shows **only the bolt**: there is no
    /// "remaining" figure worth reporting on mains power, and the percentage would compete with the
    /// bolt for the same small space. On battery the percentage goes inside the outline and the
    /// remaining time goes after it, each controlled by its own switch.
    public static func readings(externalConnected: Bool,
                                showsPercent: Bool,
                                showsTime: Bool,
                                percent: Double?,
                                minutesRemaining: Int?) -> MenuBarReadings {
        guard !externalConnected else { return MenuBarReadings() }
        return MenuBarReadings(iconText: showsPercent ? percentText(percent) : nil,
                               trailingText: showsTime ? compactTime(minutesRemaining) : nil)
    }
}

/// How the menu bar glyph itself is drawn.
public enum MenuBarIconState {

    /// The bolt means "a charger is attached" — not "currently taking on charge".
    ///
    /// macOS behaves this way too: the bolt stays visible when the battery is full or when a
    /// charge limit has paused charging, because the meaningful fact is that the Mac is on
    /// external power. `isCharging` is still accepted so a machine that reports charging
    /// without a connected adapter never loses the bolt.
    public static func showsBolt(externalConnected: Bool, isCharging: Bool) -> Bool {
        externalConnected || isCharging
    }

    /// Whether the percentage can be drawn inside the glyph.
    ///
    /// The custom battery outline has room for digits; a fixed SF Symbol does not, so there the
    /// percentage has to be shown beside the icon instead.
    public static func percentGoesInsideIcon(customGlyph: Bool, showsPercent: Bool) -> Bool {
        showsPercent && customGlyph
    }
}

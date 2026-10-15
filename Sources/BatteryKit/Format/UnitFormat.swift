import Foundation

/// Shared number/unit formatting so the card, the detail window, the CLI and the
/// notifications all agree on how a value looks.
public enum UnitFormat {

    public static func percent(_ value: Double?, fractionDigits: Int = 0) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(fractionDigits)f%%", value)
    }

    public static func watts(_ value: Double?, fractionDigits: Int = 2) -> String {
        guard let value else { return "—" }
        let magnitude = abs(value)
        if magnitude >= 100 { return String(format: "%.0f W", value) }
        // Two decimals everywhere below 100 W. The SMC reports these powers at ~1 Hz with
        // sub-0.1 W resolution, so rounding a 33.4 W adapter reading to one decimal threw away
        // the very movement that makes it visibly live — while a sub-10 W value kept two
        // decimals and looked far more "alive" than it really was.
        return String(format: "%.\(fractionDigits)f W", value)
    }

    public static func signedWatts(_ value: Double?, fractionDigits: Int = 2) -> String {
        guard let value else { return "—" }
        let sign = value > 0 ? "+" : (value < 0 ? "−" : "")
        return sign + watts(abs(value), fractionDigits: fractionDigits)
    }

    public static func volts(_ value: Double?, fractionDigits: Int = 2) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(fractionDigits)f V", value)
    }

    public static func millivolts(_ value: Double?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f mV", value * 1000)
    }

    public static func amps(_ value: Double?, fractionDigits: Int = 3) -> String {
        guard let value else { return "—" }
        let magnitude = abs(value)
        if magnitude < 0.001 { return String(format: "%.0f mA", value * 1000) }
        return String(format: "%.\(fractionDigits)f A", value)
    }

    public static func signedAmps(_ value: Double?, fractionDigits: Int = 3) -> String {
        guard let value else { return "—" }
        let sign = value > 0 ? "+" : (value < 0 ? "−" : "")
        return sign + amps(abs(value), fractionDigits: fractionDigits)
    }

    public static func milliampHours(_ value: Int?) -> String {
        guard let value else { return "—" }
        return "\(grouped(value)) mAh"
    }

    public static func capacityDual(_ value: Int?, reference: Int?) -> String {
        guard let value else { return "—" }
        var text = "\(grouped(value)) mAh"
        if let reference, reference > 0 {
            text += String(format: " (%.1f%%)", Double(value) / Double(reference) * 100)
        }
        return text
    }

    public static func celsius(_ value: Double?, fractionDigits: Int = 1) -> String {
        guard let value else { return "—" }
        return String(format: "%.\(fractionDigits)f °C", value)
    }

    public static func minutes(_ value: Int?) -> String {
        guard let value, value > 0 else { return "—" }
        if value < 60 { return "\(value) 分钟" }
        return "\(value / 60) 小时 \(value % 60) 分钟"
    }

    public static func hoursFromMinutes(_ value: Int?) -> String {
        guard let value, value > 0 else { return "—" }
        return String(format: "%.1f 小时", Double(value) / 60)
    }

    /// Compact duration for chart axes and "since" labels.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) 秒" }
        if total < 3600 { return "\(total / 60) 分钟" }
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分"
    }

    public static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func dateTime(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }

    public static func timeOnly(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

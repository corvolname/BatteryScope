import Foundation
import UserNotifications
import BatteryKit

/// Local notifications for the battery events worth interrupting someone for.
///
/// Everything is guarded by `isAvailable`: `UNUserNotificationCenter` traps when the process
/// is not running from a real `.app` bundle, which is the case when the raw executable is
/// launched straight out of `.build` during development.
final class Notifier {

    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    private var didRequestAuthorization = false
    private var lastLowBatteryNotification: Date?
    private var lastFullChargeNotification: Date?
    /// Suppress repeats: these events stay true for a long time and must not nag.
    private let repeatInterval: TimeInterval = 30 * 60

    func requestAuthorizationIfNeeded() {
        guard Self.isAvailable, !didRequestAuthorization else { return }
        didRequestAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func powerSourceChanged(connected: Bool, percent: Double?) {
        guard Self.isAvailable else { return }
        let percentText = percent.map { String(format: "，当前电量 %.0f%%", $0) } ?? ""
        post(identifier: "powerSource",
             title: connected ? "已接通电源" : "已切换到电池供电",
             body: connected
                ? "正在使用外接电源供电\(percentText)。"
                : "已断开电源，正在使用电池\(percentText)。")
    }

    func fullyCharged(percent: Double?) {
        guard Self.isAvailable else { return }
        if let last = lastFullChargeNotification, Date().timeIntervalSince(last) < repeatInterval { return }
        lastFullChargeNotification = Date()
        post(identifier: "fullyCharged",
             title: "电池已充满",
             body: percent.map { String(format: "电量 %.0f%%，可以拔掉电源以延长电池寿命。", $0) }
                ?? "可以拔掉电源以延长电池寿命。")
    }

    func lowBattery(percent: Double, threshold: Double) {
        guard Self.isAvailable else { return }
        if let last = lastLowBatteryNotification, Date().timeIntervalSince(last) < repeatInterval { return }
        lastLowBatteryNotification = Date()
        post(identifier: "lowBattery",
             title: "电池电量偏低",
             body: String(format: "当前电量 %.0f%%，已低于 %.0f%%，建议接上电源。", percent, threshold))
    }

    private func post(identifier: String, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // A nil trigger delivers immediately.
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

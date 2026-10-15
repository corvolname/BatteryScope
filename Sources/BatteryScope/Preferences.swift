import SwiftUI
import Combine
import BatteryKit

/// UserDefaults-backed settings.
///
/// Only genuine preferences live here. Health is always the measured value, so there is no
/// algorithm to choose; every property writes through on change.
final class Preferences: ObservableObject {

    private enum Key: String {
        case settingsVersion = "settingsVersion"
        case menuBarShowsPercent = "menuBarShowsPercent"
        case menuBarShowsTime = "menuBarShowsTime"
        case samplingInterval = "samplingInterval"
        case powerSource = "powerSource"
        case launchAtLogin = "launchAtLogin"
        case notifyPowerSource = "notifyPowerSource"
        case notifyFullyCharged = "notifyFullyCharged"
        case notifyLowBattery = "notifyLowBattery"
        case lowBatteryThreshold = "lowBatteryThreshold"
        case keepHistory = "keepHistory"
    }

    /// Bumped whenever the shipped defaults change in a way users should see immediately.
    private static let currentSettingsVersion = 4

    private let defaults = UserDefaults.standard

    /// Draws the charge percentage inside the battery outline. On by default.
    ///
    /// Only meaningful on battery power: while a charger is attached the outline shows the bolt
    /// alone.
    @Published var menuBarShowsPercent: Bool {
        didSet { defaults.set(menuBarShowsPercent, forKey: Key.menuBarShowsPercent.rawValue) }
    }
    /// Draws the remaining time after the icon in `4h 30m` form. Off by default, because the
    /// estimate is a slow-moving prediction rather than a live reading. Also battery-only.
    @Published var menuBarShowsTime: Bool {
        didSet { defaults.set(menuBarShowsTime, forKey: Key.menuBarShowsTime.rawValue) }
    }
    /// Seconds between reads. The kernel refreshes the battery registers about once a second,
    /// so 1 s is both the fastest useful value and the default.
    @Published var samplingInterval: Double {
        didSet { defaults.set(samplingInterval, forKey: Key.samplingInterval.rawValue) }
    }
    /// Which battery-power reading to trust. See `BatterySnapshot.BatteryPowerSource`.
    @Published var powerSource: BatterySnapshot.BatteryPowerSource {
        didSet { defaults.set(powerSource.rawValue, forKey: Key.powerSource.rawValue) }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin.rawValue)
            launchAtLoginError = LoginItem.update(enabled: launchAtLogin)
        }
    }
    @Published var notifyPowerSource: Bool {
        didSet { defaults.set(notifyPowerSource, forKey: Key.notifyPowerSource.rawValue) }
    }
    @Published var notifyFullyCharged: Bool {
        didSet { defaults.set(notifyFullyCharged, forKey: Key.notifyFullyCharged.rawValue) }
    }
    @Published var notifyLowBattery: Bool {
        didSet { defaults.set(notifyLowBattery, forKey: Key.notifyLowBattery.rawValue) }
    }
    @Published var lowBatteryThreshold: Double {
        didSet { defaults.set(lowBatteryThreshold, forKey: Key.lowBatteryThreshold.rawValue) }
    }
    @Published var keepHistory: Bool {
        didSet { defaults.set(keepHistory, forKey: Key.keepHistory.rawValue) }
    }

    /// Populated when "launch at login" could not be applied, so the pane can say so instead of
    /// silently reverting the toggle.
    @Published var launchAtLoginError: String?

    init() {
        // The first release shipped a saturated palette and a 2 s cadence. The redesigned UI
        // follows macOS conventions (monochrome menu bar icon, 1 s refresh), so those style
        // overrides are cleared exactly once rather than leaving the old look in place.
        // Version 4 also drops the icon/colour pickers and the charge-limit watchdog entirely.
        let storedVersion = defaults.integer(forKey: Key.settingsVersion.rawValue)
        if storedVersion < Self.currentSettingsVersion {
            // Retired settings, removed by literal name because their enum cases are gone: the
            // menu bar icon is no longer customisable, so the style keys are meaningless now.
            for key in ["iconStyle", "colorMode", "menuBarLabel",
                        "chargeLimitEnabled", "chargeLimitPercent"] {
                defaults.removeObject(forKey: key)
            }
            defaults.set(Self.currentSettingsVersion, forKey: Key.settingsVersion.rawValue)
        }
        // Orphan from the release that offered a choice of health formula (measured vs nominal).
        // Health is always measured now, so the key has no reader left.
        defaults.removeObject(forKey: "healthFormula")

        // Replaced the four-way `menuBarLabel` choice: the percentage now lives inside the
        // glyph and only the time is optional trailing text.
        menuBarShowsPercent = defaults.object(forKey: Key.menuBarShowsPercent.rawValue) as? Bool ?? true
        menuBarShowsTime = defaults.object(forKey: Key.menuBarShowsTime.rawValue) as? Bool ?? false
        samplingInterval = defaults.object(forKey: Key.samplingInterval.rawValue) as? Double ?? 1
        powerSource = (defaults.string(forKey: Key.powerSource.rawValue)
            .flatMap(BatterySnapshot.BatteryPowerSource.init(rawValue:))) ?? .automatic
        launchAtLogin = LoginItem.isEnabled
        notifyPowerSource = defaults.object(forKey: Key.notifyPowerSource.rawValue) as? Bool ?? false
        notifyFullyCharged = defaults.object(forKey: Key.notifyFullyCharged.rawValue) as? Bool ?? true
        notifyLowBattery = defaults.object(forKey: Key.notifyLowBattery.rawValue) as? Bool ?? true
        lowBatteryThreshold = defaults.object(forKey: Key.lowBatteryThreshold.rawValue) as? Double ?? 20
        keepHistory = defaults.object(forKey: Key.keepHistory.rawValue) as? Bool ?? true
    }

    func clearHistory(monitor: BatteryMonitor) {
        monitor.history.clearLive()
        monitor.history.clearArchive()
    }
}

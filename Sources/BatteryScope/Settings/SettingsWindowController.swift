import SwiftUI
import AppKit
import BatteryKit

/// The preferences window. Deliberately contains **only** settings — no "about" block, no data
/// source documentation, no machine information. Those belong in the README, not in a pane the
/// user opens to flip a switch.
struct SettingsView: View {

    @ObservedObject var monitor: BatteryMonitor
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Section("菜单栏") {
                Toggle("显示电量百分比", isOn: $preferences.menuBarShowsPercent)
                Toggle("显示剩余时间", isOn: $preferences.menuBarShowsTime)

            }

            Section("功率数据来源") {
                Picker("电池功率", selection: $preferences.powerSource) {
                    ForEach(BatterySnapshot.BatteryPowerSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
            }

            Section("刷新") {
                Picker("刷新间隔", selection: $preferences.samplingInterval) {
                    Text("1 秒").tag(1.0)
                    Text("2 秒").tag(2.0)
                    Text("5 秒").tag(5.0)
                    Text("10 秒").tag(10.0)
                }
                Toggle("保留历史记录", isOn: $preferences.keepHistory)
                HStack {
                    Text("历史记录")
                    Spacer()
                    Button("清除") {
                        preferences.clearHistory(monitor: monitor)
                    }
                    .controlSize(.small)
                }
            }

            Section("通知") {
                Toggle("接通 / 断开电源", isOn: $preferences.notifyPowerSource)
                Toggle("电池充满", isOn: $preferences.notifyFullyCharged)
                Toggle("电量偏低", isOn: $preferences.notifyLowBattery)
                if preferences.notifyLowBattery {
                    HStack {
                        Text("低电量阈值")
                        Slider(value: $preferences.lowBatteryThreshold, in: 5...50, step: 5)
                        Text("\(Int(preferences.lowBatteryThreshold))%")
                            .monospacedDigit()
                            .frame(width: 38, alignment: .trailing)
                    }
                }
                if !Notifier.isAvailable {
                    Label("从 .app 启动后通知才可用。", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Theme.advisory)
                }
            }

            Section {
                Toggle("开机时自动启动", isOn: $preferences.launchAtLogin)
                if let error = preferences.launchAtLoginError {
                    Text("无法设置：\(error)")
                        .font(.caption)
                        .foregroundStyle(Theme.advisory)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
    }
}


/// Hosts the preferences window as its own small window, separate from the detail window.
final class SettingsWindowController {

    private var window: NSWindow?
    private let monitor: BatteryMonitor
    private let preferences: Preferences

    init(monitor: BatteryMonitor, preferences: Preferences) {
        self.monitor = monitor
        self.preferences = preferences
    }

    func show() {
        if window == nil { makeWindow() }
        guard let window else { return }
        // An .accessory app has to be activated explicitly or the window opens behind others.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() {
        let hosting = NSHostingController(rootView: SettingsView(monitor: monitor, preferences: preferences))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 700),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "偏好设置"
        window.contentViewController = hosting
        // Size to whatever the form actually needs, so no section is ever clipped (the low
        // battery threshold row only exists while that notification is enabled).
        hosting.view.layoutSubtreeIfNeeded()
        let fitting = hosting.view.fittingSize
        if fitting.height > 200 {
            window.setContentSize(NSSize(width: 460, height: fitting.height))
        }
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window
    }
}

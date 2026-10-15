import AppKit
import SwiftUI
import Combine
import BatteryKit

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var monitor: BatteryMonitor!
    private var preferences: Preferences!
    private var appState: AppState!
    private var statusController: StatusItemController!
    private var detailController: DetailWindowController!
    private var settingsController: SettingsWindowController!
    private let notifier = Notifier()

    private var cancellables = Set<AnyCancellable>()
    private var previousSnapshot: BatterySnapshot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences = Preferences()
        appState = AppState()
        monitor = BatteryMonitor()
        // 1 s by default: the kernel refreshes the battery registers about once a second, so the
        // card is genuinely live the whole time it is open.
        monitor.samplingInterval = preferences.samplingInterval
        monitor.powerSource = preferences.powerSource
        monitor.history.isPersistenceEnabled = preferences.keepHistory

        let cardActions = CardActions(
            openSettings: { [weak self] in self?.settingsController.show() }
        )
        let menuActions = MenuActions(
            openDetail: { [weak self] in self?.detailController.show() },
            openSettings: { [weak self] in self?.settingsController.show() },
            copyReport: { [weak self] in self?.copyReport() },
            quit: { NSApp.terminate(nil) }
        )

        settingsController = SettingsWindowController(monitor: monitor, preferences: preferences)
        detailController = DetailWindowController(monitor: monitor, appState: appState)
        statusController = StatusItemController(monitor: monitor,
                                               preferences: preferences,
                                               appState: appState,
                                               cardActions: cardActions,
                                               menuActions: menuActions)
        statusController.start()

        installMainMenu()

        wirePreferences()
        wireNotifications()

        monitor.start()
        applyDevelopmentHooks()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Main menu

    /// A main menu that is never seen, so the standard shortcuts resolve.
    ///
    /// A key equivalent is dispatched by searching `NSApp.mainMenu`, and this app is an
    /// `LSUIElement` accessory with no menu bar, so it had no main menu at all: **⌘W did nothing at
    /// all**, and neither did ⌘Q, ⌘M, ⌘C or ⌘A. The window is `.closable` and its close button
    /// works — the shortcut simply had nothing to trigger it.
    ///
    /// The items carry no targets: they travel the responder chain to whichever window is key, which
    /// is what makes one Close item work for the detail window and the preferences window alike.
    /// Nothing here is visible, so the titles exist only for the sake of being standard.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 BatteryScope",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 BatteryScope",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 BatteryScope",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "关闭窗口",
                         action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // The detail window's values are selectable, so the edit shortcuts need to exist too.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "窗口")
        windowMenu.addItem(withTitle: "最小化",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Preferences → monitor

    private func wirePreferences() {
        preferences.$samplingInterval
            .dropFirst()
            .sink { [weak self] interval in self?.monitor.samplingInterval = interval }
            .store(in: &cancellables)

        preferences.$powerSource
            .dropFirst()
            .sink { [weak self] source in self?.monitor.powerSource = source }
            .store(in: &cancellables)

        preferences.$keepHistory
            .dropFirst()
            .sink { [weak self] enabled in
                self?.monitor.history.isPersistenceEnabled = enabled
                if !enabled { self?.monitor.history.clearArchive() }
            }
            .store(in: &cancellables)

        // Ask for notification permission the first time any notify toggle goes on.
        // `hasAnyNotificationEnabled` is derived, so it is combined from the three flags.
        Publishers.CombineLatest3(preferences.$notifyPowerSource,
                                  preferences.$notifyFullyCharged,
                                  preferences.$notifyLowBattery)
            .map { $0 || $1 || $2 }
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled { self?.notifier.requestAuthorizationIfNeeded() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Notifications

    private func wireNotifications() {
        monitor.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshot in
                guard let self else { return }
                defer { if snapshot != nil { self.previousSnapshot = snapshot } }

                let events = BatteryEventDetector.detect(
                    previous: self.previousSnapshot,
                    current: snapshot,
                    lowBatteryThreshold: self.preferences.lowBatteryThreshold)
                if self.preferences.notifyPowerSource, let connected = events.powerSourceChanged {
                    self.notifier.powerSourceChanged(connected: connected, percent: snapshot?.chargePercent)
                }
                if self.preferences.notifyFullyCharged, events.becameFullyCharged {
                    self.notifier.fullyCharged(percent: snapshot?.chargePercent)
                }
                if self.preferences.notifyLowBattery, let percent = events.crossedLowBatteryThreshold {
                    self.notifier.lowBattery(percent: percent, threshold: self.preferences.lowBatteryThreshold)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    private func copyReport() {
        guard let snapshot = monitor.snapshot else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(snapshot.textReport(), forType: .string)
    }

    /// Development/inspection hooks, driven by environment variables so they can never fire
    /// during normal use:
    ///
    ///     BATTERYSCOPE_SHOW_CARD=1                                    open the card after launch
    ///     BATTERYSCOPE_SHOW_DETAIL=overview|charts|rawKeys            open a detail tab
    ///     BATTERYSCOPE_SHOW_SETTINGS=1                                open preferences
    ///     BATTERYSCOPE_SHOW_PERCENT_OFF=1                             hide the menu bar percentage
    ///     BATTERYSCOPE_TEST_CMDW=1                                    verify ⌘W closes the window
    ///
    /// They exist so the UI can be screenshotted and verified without needing accessibility
    /// permissions to synthesise a click on the status item. `BATTERYSCOPE_TEST_CMDW` goes one step
    /// further: a script cannot bring an accessory app to the front, so a synthesised keystroke can
    /// never reach this app's menu — the app therefore synthesises the ⌘W event itself and reports
    /// whether the menu dispatched it and whether the window actually closed.
    private func applyDevelopmentHooks() {
        let environment = ProcessInfo.processInfo.environment

        // BATTERYSCOPE_MENU_LABEL takes the old option names for convenience, so existing
        // screenshot scripts keep working: iconOnly / percent / timeRemaining / percentAndTime.
        if let raw = environment["BATTERYSCOPE_MENU_LABEL"] {
            switch raw {
            case "iconOnly":
                preferences.menuBarShowsPercent = false
                preferences.menuBarShowsTime = false
            case "percent":
                preferences.menuBarShowsPercent = true
                preferences.menuBarShowsTime = false
            case "timeRemaining":
                preferences.menuBarShowsPercent = false
                preferences.menuBarShowsTime = true
            case "percentAndTime":
                preferences.menuBarShowsPercent = true
                preferences.menuBarShowsTime = true
            default:
                break
            }
        }
        if let raw = environment["BATTERYSCOPE_SHOW_DETAIL"], let tab = DetailTab(rawValue: raw) {
            print("BatteryScope: BATTERYSCOPE_SHOW_DETAIL=\(tab.rawValue) -> 打开详情窗口")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.appState.selectedTab = tab
                self?.detailController.show()
            }
        } else if let raw = environment["BATTERYSCOPE_SHOW_DETAIL"] {
            print("BatteryScope: 无法识别的 BATTERYSCOPE_SHOW_DETAIL=\(raw)（可用值：overview/charts/rawKeys）")
        }

        // 验证 ⌘W：合成一个快捷键事件，走与真实按键完全相同的分发路径
        // （NSApp.mainMenu 的 performKeyEquivalent）。脚本无法把 accessory 应用置前，
        // 所以按键注入测不了这条路径。
        if environment["BATTERYSCOPE_TEST_CMDW"] != nil {
            // 写到 stderr：重定向到文件时 stdout 是块缓冲的，进程被杀前不会 flush。
            func report(_ message: String) {
                FileHandle.standardError.write(("BatteryScope: " + message + "\n").data(using: .utf8)!)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                guard let self else { return }
                let menuDump = NSApp.mainMenu?.items.map { item in
                    (item.submenu?.items ?? []).map { sub in
                        "\(sub.title)[\(sub.keyEquivalent):\(sub.action.map(NSStringFromSelector) ?? "nil")]"
                    }.joined(separator: " ")
                }.joined(separator: " / ") ?? "无主菜单"
                report("主菜单 -> " + menuDump)

                NSApp.activate(ignoringOtherApps: true)
                guard let window = self.detailController.window else { report("详情窗口不存在"); return }
                window.makeKeyAndOrderFront(nil)
                report("⌘W 前 visible=\(window.isVisible) key=\(window.isKeyWindow)")
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                                   timestamp: ProcessInfo.processInfo.systemUptime,
                                                   windowNumber: window.windowNumber, context: nil,
                                                   characters: "w", charactersIgnoringModifiers: "w",
                                                   isARepeat: false, keyCode: 13) else {
                    report("无法合成事件"); return
                }
                let handled = NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
                report("performKeyEquivalent 返回 \(handled)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    report("⌘W 后 visible=\(window.isVisible)")
                }
            }
        }
        if environment["BATTERYSCOPE_TEST_CLICKGUARD"] != nil {
            func report(_ message: String) {
                FileHandle.standardError.write(("BatteryScope: " + message + "\n").data(using: .utf8)!)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self,
                      let button = self.statusController.statusButton,
                      let window = button.window else { report("状态栏按钮不存在"); return }

                let centreInWindow = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
                let centreOnScreen = window.convertPoint(toScreen: button.convert(centreInWindow, to: nil))
                // 往里缩 1 pt：CGRect.contains 是半开区间，正好落在 max 边上会被判为外部。
                let cornerInWindow = NSPoint(x: button.bounds.maxX - 1, y: button.bounds.maxY - 1)
                let cornerOnScreen = window.convertPoint(toScreen: button.convert(cornerInWindow, to: nil))
                let outsideOnScreen = NSPoint(x: centreOnScreen.x - 300, y: centreOnScreen.y + 300)

                report("主屏=\(NSStringFromRect(NSScreen.main?.frame ?? .zero)) 屏数=\(NSScreen.screens.count)")
                report("当前指针=\(NSStringFromPoint(NSEvent.mouseLocation))")
                report("按钮窗口=\(NSStringFromRect(window.frame)) bounds=\(NSStringFromRect(button.bounds))")
                report("按钮窗口 isVisible=\(window.isVisible) level=\(window.level.rawValue)")
                report("图标中心 \(NSStringFromPoint(centreOnScreen)) -> \(self.statusController.isPointOnStatusItem(centreOnScreen))（应为 true）")
                report("按钮边角 \(NSStringFromPoint(cornerOnScreen)) -> \(self.statusController.isPointOnStatusItem(cornerOnScreen))（应为 true）")
                report("按钮外侧 \(NSStringFromPoint(outsideOnScreen)) -> \(self.statusController.isPointOnStatusItem(outsideOnScreen))（应为 false）")

                // 真实指针：移到图标上，确认实时判断也是 true（监视器用的就是它）。
                // CGWarpMouseCursorPosition 用左上原点，AppKit 用左下原点——直接传会把指针
                // 镜像送到屏幕另一端（实测落到 {1836, 20}），必须翻转 y。
                let screenHeight = NSScreen.main?.frame.height ?? 0
                CGWarpMouseCursorPosition(NSPoint(x: centreOnScreen.x,
                                                  y: screenHeight - centreOnScreen.y))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    report("指针=\(NSStringFromPoint(NSEvent.mouseLocation)) "
                           + "clickIsOnStatusItem=\(self.statusController.clickIsOnStatusItem)（应为 true）")
                    // 再移到远处，确认会返回 false
                    CGWarpMouseCursorPosition(NSPoint(x: 400, y: 400))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        report("指针移到远处后 clickIsOnStatusItem="
                               + "\(self.statusController.clickIsOnStatusItem)（应为 false）")
                    }
                }
            }
        }
        if environment["BATTERYSCOPE_SHOW_SETTINGS"] != nil {
            print("BatteryScope: BATTERYSCOPE_SHOW_SETTINGS -> 打开偏好设置")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.settingsController.show()
            }
        }
        if environment["BATTERYSCOPE_SHOW_CARD"] != nil {
            print("BatteryScope: BATTERYSCOPE_SHOW_CARD -> 打开弹出卡片")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.statusController.togglePopover()
            }
        }
        // Opens the card and then genuinely closes it, so the cost of a closed card can be
        // measured. Without this the card appears to stay open: launched from a shell the app never
        // becomes active, so the resign-active auto-close never fires and every "closed" reading is
        // really an open one.
        if let raw = environment["BATTERYSCOPE_CLOSE_CARD_AFTER"], let delay = Double(raw) {
            print("BatteryScope: BATTERYSCOPE_CLOSE_CARD_AFTER=\(delay) -> 到点关闭卡片")
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.statusController.closePopover()
                let shown = self?.statusController.isPopoverShown ?? false
                print("BatteryScope: 卡片关闭 -> isShown=\(shown)")
            }
        }
        if environment["BATTERYSCOPE_SHOW_MENU"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.statusController.showContextMenu()
            }
        }
        if environment["BATTERYSCOPE_TOGGLE_STRESS"] != nil {
            // open → close → open, so a screenshot taken at 3 s / 5 s / 7 s proves that a second
            // click collapses the card rather than re-opening it.
            print("BatteryScope: BATTERYSCOPE_TOGGLE_STRESS -> 2s 开 / 4s 合 / 6s 开")
            for (delay, label) in [(2.0, "开"), (4.0, "合"), (6.0, "开")] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.statusController.togglePopover()
                    print("BatteryScope: \(label) -> isShown=\(self?.statusController.isPopoverShown ?? false)")
                }
            }
        }
    }
}

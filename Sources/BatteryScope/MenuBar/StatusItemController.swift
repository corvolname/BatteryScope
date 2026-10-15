import AppKit
import SwiftUI
import Combine
import BatteryKit

/// Owns the menu bar item: the drawn glyph, the optional percentage label, the popover card and
/// the right-click menu.
final class StatusItemController: NSObject, NSPopoverDelegate {

    private let statusItem: NSStatusItem
    private let popover = NSPopover()

    /// Releases the card's view hierarchy when the popover closes.
    ///
    /// The hosting controller used to survive the first open, so the card kept re-evaluating its
    /// `body` — and its charge animation kept ticking — while nobody could see it. Measured at
    /// ~2.5 % CPU with every window closed, on a 1 % idle baseline. Rebuilding it on the next open
    /// costs nothing that matters: the numbers it shows live in the monitor, not in the view.
    func popoverDidClose(_ notification: Notification) {
        trace("popoverDidClose")
        popover.contentViewController = nil
    }
    private let contextMenu = NSMenu()

    private let monitor: BatteryMonitor
    private let preferences: Preferences
    private let appState: AppState
    private let cardActions: CardActions
    private let menuActions: MenuActions

    private var cancellables = Set<AnyCancellable>()
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?

    init(monitor: BatteryMonitor,
         preferences: Preferences,
         appState: AppState,
         cardActions: CardActions,
         menuActions: MenuActions) {
        self.monitor = monitor
        self.preferences = preferences
        self.appState = appState
        self.cardActions = cardActions
        self.menuActions = menuActions
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    deinit {
        removeOutsideClickMonitors()
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
    }

    func start() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(handleClick)
        // Registering for both mouse-up events is what lets a right-click open a menu while a
        // left-click toggles the popover.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeading

        buildContextMenu()
        observeSources()
        refresh()
    }

    // MARK: - Observation

    private func observeSources() {
        monitor.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        monitor.$isAvailable
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // objectWillChange fires *before* the value changes, so hop to the next run-loop turn.
        preferences.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }
            .store(in: &cancellables)
    }

    // MARK: - Icon

    private func refresh() {
        guard let button = statusItem.button else { return }
        let snapshot = monitor.snapshot

        guard monitor.isAvailable else {
            let image = NSImage(systemSymbolName: "powerplug", accessibilityDescription: "无电池")
            image?.isTemplate = true
            button.image = image
            button.title = ""
            button.toolTip = "此 Mac 没有内置电池"
            return
        }

        // While charging the useful estimate is time-to-full; otherwise time-to-empty. These come
        // from the monitor already smoothed and rate-limited, so the menu bar does not flicker.
        let minutes = snapshot?.isCharging == true
            ? monitor.bestTimeToFullMinutes
            : monitor.bestTimeToEmptyMinutes

        let externalConnected = snapshot?.externalConnected ?? false
        let readings = MenuBarPresentation.readings(
            externalConnected: externalConnected,
            showsPercent: preferences.menuBarShowsPercent,
            showsTime: preferences.menuBarShowsTime,
            percent: snapshot?.chargePercent,
            minutesRemaining: minutes)

        button.image = MenuBarIconRenderer.image(
            percent: snapshot?.chargePercent,
            isCharging: snapshot?.isCharging ?? false,
            externalConnected: externalConnected,
            iconText: readings.iconText,
            lowBatteryThreshold: preferences.lowBatteryThreshold
        )

        // The remaining time sits after the icon, in the menu bar's own colour except when the
        // charge is low, where matching the glyph reads as a warning rather than decoration.
        let text = readings.trailingText ?? ""
        if text.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
            button.title = ""
        } else if let percent = snapshot?.chargePercent,
                  let color = MenuBarIconRenderer.labelColor(
                    percent: percent,
                    externalConnected: externalConnected,
                    lowBatteryThreshold: preferences.lowBatteryThreshold) {
            button.attributedTitle = NSAttributedString(
                string: text,
                attributes: [.foregroundColor: color, .font: NSFont.menuBarFont(ofSize: 0)])
        } else {
            button.attributedTitle = NSAttributedString(string: "")
            button.title = text
        }

        button.toolTip = tooltip(for: snapshot)

        // A shown popover stays anchored to the rectangle it was handed, so if the item's width
        // changes while it is open — the optional trailing time appearing or growing a digit — it
        // has to be re-anchored or it drifts away from the icon.
        if popover.isShown, let button = statusItem.button {
            popover.positioningRect = button.bounds
        }
    }

    private func tooltip(for snapshot: BatterySnapshot?) -> String {
        guard let snapshot else { return "正在读取电池信息…" }
        var lines = ["BatteryScope — \(snapshot.powerSourceDescription)"]
        if let percent = snapshot.chargePercent {
            lines.append(String(format: "电量 %.0f%%", percent))
        }
        if let health = snapshot.healthPercent {
            lines.append(String(format: "健康度 %.1f%%", health))
        }
        if let power = snapshot.effectiveBatteryPowerWatts, abs(power) > 0.05 {
            lines.append("电池功率 \(UnitFormat.signedWatts(power))")
        }
        if let load = snapshot.systemLoadWatts {
            lines.append("整机功耗 \(UnitFormat.watts(load))")
        }
        if let input = snapshot.adapterInputWatts, snapshot.externalConnected {
            lines.append("适配器供电 \(UnitFormat.watts(input))")
        }
        if let temperature = snapshot.temperatureCelsius {
            lines.append("温度 \(UnitFormat.celsius(temperature))")
        }
        if let cycles = snapshot.cycleCount {
            lines.append("循环 \(cycles) 次")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Context menu

    private func buildContextMenu() {
        let menu = contextMenu
        menu.removeAllItems()
        menu.addItem(menuItem("偏好设置…", #selector(openSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(menuItem("详情窗口…", #selector(openDetail), key: "d"))
        menu.addItem(menuItem("复制电池报告", #selector(copyReport), key: "c"))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出 BatteryScope", #selector(quit), key: "q"))
    }

    private func menuItem(_ title: String, _ selector: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - Click handling

    @objc private func handleClick() {
        trace("handleClick: eventType=\(NSApp.currentEvent?.type.rawValue ?? 0)")
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isSecondary {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    func showContextMenu() {
        guard let window = statusItem.button?.window else { return }

        // Positioned explicitly rather than through `statusItem.menu` + `performClick`.
        //
        // That route anchors the menu below the status item's *window*, and on this macOS that
        // window is 65 pt tall and reaches 13 pt above the top of the screen — so the menu landed
        // 27 pt lower than every system menu. Measured: ours at y=66, the Apple menu at y=40, with
        // the menu bar ending at 39.
        //
        // The point `popUp` takes is the menu's **bottom-left**, not its top-left. Passing the menu
        // bar's bottom edge therefore asked for a menu hanging *above* the screen: macOS clamped it
        // down, and — the visible symptom — added a scroll chevron and hid the first item
        // (偏好设置) until hovered. Subtracting the menu's own height puts the bottom where the top
        // was meant to be.
        let screen = window.screen ?? NSScreen.main
        let top = screen?.frame.maxY ?? 0
        let menuBarHeight = top - (screen?.visibleFrame.maxY ?? top)
        if ProcessInfo.processInfo.environment["BATTERYSCOPE_TRACE_POPOVER"] != nil {
            let info = "button=\(NSStringFromRect(statusItem.button?.frame ?? .zero)) "
                + "bounds=\(NSStringFromRect(statusItem.button?.bounds ?? .zero)) "
                + "image=\(statusItem.button?.image.map { NSStringFromSize($0.size) } ?? "nil") "
                + "window=\(NSStringFromRect(window.frame)) "
                + "menuSize=\(NSStringFromSize(contextMenu.size)) "
                + "screen=\(NSStringFromRect(screen?.frame ?? .zero)) "
                + "visible=\(NSStringFromRect(screen?.visibleFrame ?? .zero))\n"
            FileHandle.standardError.write(("MENUINFO " + info).data(using: .utf8)!)
        }
        // 8 pt below the menu bar, not flush with it.
        //
        // Anchored flush, macOS decided the menu did not fit and collapsed it: it drew a scroll
        // chevron and hid 偏好设置 until hovered, and the window came out 6 pt shorter than
        // `contextMenu.size.height` (122 against 128) — that 6 pt is the room the menu's own notch
        // needs above its frame. Measured across insets:
        //
        //     inset  0 → y=40  h=122  (collapsed)
        //     inset  4 → y=40  h=126  (collapsed)
        //     inset  8 → y=42  h=128  (full)
        //     inset 12 → y=46  h=128  (full)
        //
        // 8 is the smallest inset that reliably gives the full menu, and 42 is 2 pt from where the
        // system's own Apple menu sits (y=40).
        let inset: CGFloat = 8
        contextMenu.popUp(positioning: nil,
                          at: NSPoint(x: window.frame.minX,
                                      y: top - menuBarHeight - inset),
                          in: nil)
    }

    /// Whether a screen point is inside our own status item button.
    ///
    /// The screen point is taken into the button's own coordinate space rather than compared against
    /// the status bar window, so the answer cannot depend on how wide that private window happens to
    /// be — a click on the neighbouring item must still count as an outside click and close the card.
    func isPointOnStatusItem(_ screenPoint: NSPoint) -> Bool {
        guard let button = statusItem.button, let window = button.window else { return false }
        let inWindow = window.convertPoint(fromScreen: screenPoint)
        return button.bounds.contains(button.convert(inWindow, from: nil))
    }

    /// Asked during a mouse-down callback, so the pointer is at the click point.
    var clickIsOnStatusItem: Bool { isPointOnStatusItem(NSEvent.mouseLocation) }

    /// The status item's button, for the development hooks that verify the click guard.
    var statusButton: NSButton? { statusItem.button }

    /// Left-click toggles the card: open if closed, close if open.
    /// 事件追踪：把切换过程的每一步按时间戳写到 stderr。
    ///
    /// 「点第二次反而重新展开」是事件顺序问题，只看代码得不出结论——需要看到监视器、
    /// handleClick、show/close 实际发生的顺序。
    private func trace(_ message: String) {
        guard ProcessInfo.processInfo.environment["BATTERYSCOPE_TRACE_POPOVER"] != nil else { return }
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000))
        FileHandle.standardError.write("TRACE \(stamp) \(message)\n".data(using: .utf8)!)
    }

    func togglePopover() {
        trace("togglePopover: isShown=\(popover.isShown)")
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    /// Exposed so the development hook can assert the toggle actually changed state.
    var isPopoverShown: Bool { popover.isShown }

    private func showPopover() {
        trace("showPopover")
        guard let button = statusItem.button else { return }

        if popover.contentViewController == nil {
            let root = CardView(monitor: monitor, actions: cardActions)
            let controller = NSHostingController(rootView: root)
            // Lets SwiftUI's intrinsic size drive the popover size, so the card is never clipped.
            controller.sizingOptions = [.preferredContentSize]
            popover.contentViewController = controller
        }

        // Read immediately so the very first frame the user sees is current, instead of waiting
        // out the sampling interval.
        monitor.readNow()

        popover.animates = false
        popover.delegate = self
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        // Since macOS 14 a background app cannot activate itself while the user is interacting
        // with another app, and AppKit then leaves the popover off screen. A real click on the
        // status item grants the focus this needs, but a scripted run has no click — so the test
        // flag forces the window on screen without stealing focus.
        if ProcessInfo.processInfo.environment["BATTERYSCOPE_KEEP_CARD_OPEN"] != nil {
            popover.contentViewController?.view.window?.orderFrontRegardless()
        }

        installOutsideClickMonitors()
    }

    func closePopover() {
        trace("closePopover")
        popover.performClose(nil)
        removeOutsideClickMonitors()
    }

    /// Closing on outside clicks is done manually rather than with `popover.behavior = .transient`.
    ///
    /// With `.transient`, AppKit closes the popover on the mouse-down that lands on the status
    /// item, and the action then sees `isShown == false` and immediately reopens it — so the
    /// second click could never collapse the card.
    private func installOutsideClickMonitors() {
        guard globalClickMonitor == nil else { return }

        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            guard let self else { return }
            // A click on our own icon belongs to the toggle, even here.
            //
            // "A global monitor never receives our own app's events" is not quite true: while the
            // app is inactive the mouse-down on the status item still reaches this monitor, which
            // then collapses the card. `handleClick` runs afterwards, finds the card already
            // closed, and reopens it — the second click appeared to flash rather than close.
            let onItem = self.clickIsOnStatusItem
            self.trace("globalMouseDown: 落在图标上=\(onItem) 指针=\(NSStringFromPoint(NSEvent.mouseLocation))")
            if onItem { return }
            self.closePopover()
        }

        localClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self else { return event }
            // Clicks on the status item (the toggle handles those) and inside the card stay put.
            let onStatusWindow = event.window === self.statusItem.button?.window
            let inCard = event.window === self.popover.contentViewController?.view.window
            self.trace("localMouseDown: 状态栏窗口=\(onStatusWindow) 卡片内=\(inCard)")
            if onStatusWindow { return event }
            if inCard { return event }
            self.closePopover()
            return event
        }

        // The auto-close-on-deactivate is skipped when BATTERYSCOPE_KEEP_CARD_OPEN is set, so a
        // scripted screenshot run cannot lose the card to whatever window grabs focus mid-capture.
        if ProcessInfo.processInfo.environment["BATTERYSCOPE_KEEP_CARD_OPEN"] == nil {
            resignObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification,
                object: nil, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                // A click on our own icon also deactivates the app — the status bar handles that
                // click itself — and this observer used to close the card there. The button's
                // action then ran on mouse-up, found the card already closed, and reopened it:
                // the second click flashed instead of collapsing.
                //
                // The pointer is still over the icon at this moment, so that is what tells the two
                // cases apart. A deactivation caused by clicking the icon is the toggle's business;
                // any other deactivation (switching to another app) still closes the card.
                let onItem = self.clickIsOnStatusItem
                self.trace("didResignActive: 指针=\(NSStringFromPoint(NSEvent.mouseLocation)) "
                           + "落在图标上=\(onItem) 按钮窗口=\(self.statusItem.button?.window.map { NSStringFromRect($0.frame) } ?? "nil")")
                if onItem {
                    self.trace("  -> 交给切换逻辑，不关闭")
                    return
                }
                self.trace("didResignActive -> closePopover")
                self.closePopover()
            }
        }
    }

    private func removeOutsideClickMonitors() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        globalClickMonitor = nil
        localClickMonitor = nil
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
    }

    // MARK: - Menu actions

    @objc private func openDetail() { menuActions.openDetail() }
    @objc private func openSettings() { menuActions.openSettings() }
    @objc private func copyReport() { menuActions.copyReport() }
    @objc private func quit() { menuActions.quit() }
}

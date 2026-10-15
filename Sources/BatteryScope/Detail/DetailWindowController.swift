import AppKit
import SwiftUI
import BatteryKit

/// Hosts the detail window. Created lazily so launching the agent costs nothing until the
/// user actually opens it, and re-used afterwards so window position and size persist.
final class DetailWindowController {

    /// 内部可见：调试钩子需要它来验证 ⌘W 的分发路径。
    private(set) var window: NSWindow?
    private let monitor: BatteryMonitor
    private let appState: AppState

    init(monitor: BatteryMonitor, appState: AppState) {
        self.monitor = monitor
        self.appState = appState
    }

    func show() {
        if window == nil { makeWindow() }
        guard let window else { return }
        // An .accessory app has to be activated explicitly or the window opens behind others.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() {
        let root = DetailView(monitor: monitor, appState: appState)
        let hosting = NSHostingView(rootView: root)
        // A standard title bar, deliberately.
        //
        // The window used to be `.fullSizeContentView` + `titlebarAppearsTransparent`, so the
        // content ran underneath the title bar. That was fine while the tab strip lived in the
        // content area; once the app declared a current SDK the tabs moved up into the title bar,
        // and the header then started behind them — the top of the charge ring was cut off. With a
        // standard title bar the content begins below it, and on macOS 26/27 that bar is already
        // the system's glass toolbar, so nothing is lost visually.
        // 760 pt of content, not 680.
        //
        // Measured with a deliberately oversized window: the overview's last row (标识 › 生产日期)
        // ends 738 pt below the top of the content area, so 680 cut off about a row and a half of
        // 寿命统计 and 标识. The height is stable now that the cards follow a fixed schema — a
        // machine on battery needs exactly the same as one plugged in — so a fixed default is right.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BatteryScope — 电池详情"
        window.contentView = hosting
        // 860 rather than 780: below this the two readings columns in the 总览 card squeeze
        // enough that the serial number truncates.
        window.minSize = NSSize(width: 860, height: 540)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BatteryScopeDetailWindow")
        if window.frame.origin == .zero { window.center() }
        self.window = window
    }
}

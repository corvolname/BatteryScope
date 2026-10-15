import SwiftUI
import BatteryKit

/// Tabs of the detail window. The detail window is intentionally *not* on the popover card any
/// more — it is reachable from the menu bar icon's context menu, so the card stays minimal.
enum DetailTab: String, CaseIterable, Identifiable {
    case overview
    case charts
    case rawKeys

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "概览"
        case .charts: return "实时图表"
        case .rawKeys: return "原始键值"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.50percent"
        case .charts: return "chart.xyaxis.line"
        case .rawKeys: return "list.bullet.rectangle"
        }
    }
}

/// UI state shared by the detail window.
final class AppState: ObservableObject {
    @Published var selectedTab: DetailTab = .overview
}

/// The popover card has exactly one action: open the preferences window.
struct CardActions {
    var openSettings: () -> Void

    static let preview = CardActions(openSettings: {})
}

/// Everything the menu bar icon's context menu can do.
struct MenuActions {
    var openDetail: () -> Void
    var openSettings: () -> Void
    var copyReport: () -> Void
    var quit: () -> Void
}

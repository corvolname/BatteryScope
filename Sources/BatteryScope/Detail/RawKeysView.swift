import SwiftUI
import AppKit
import Combine
import BatteryKit

/// A searchable, fully expanded view of every value the battery publishes.
///
/// This is the built-in replacement for
/// `ioreg -rn AppleSmartBattery | grep '"DesignCapacity"'`: it walks the whole `AppleSmartBattery`
/// subtree (Pack → Banks → Cells), *expands nested dictionaries*, and can copy the filtered
/// result back out as text.
///
/// Two deliberate implementation choices:
///
/// * Rows are rendered with `ScrollView` + `LazyVStack` rather than `List`. `List` is backed by
///   `NSTableView` on macOS, and hosting one inside a `TabView` made AppKit log
///   "reentrant operation in its NSTableView delegate" on every launch — a warning AppKit says
///   will become an assertion. A lazy stack has no table delegate to re-enter, and it gives full
///   control over the table-like styling.
/// * The flattened registry is cached in `@State` and refreshed on a slow timer instead of being
///   recomputed inside `body`, which would rebuild ~300 rows twice a second for no benefit.
struct RawKeysView: View {

    @ObservedObject var monitor: BatteryMonitor

    @State private var entries: [RawEntry] = []
    @State private var query = ""
    @State private var onlyInteresting = false
    @State private var copyConfirmation: String?

    private let refreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    /// Keys worth seeing first. Matching is on the leaf key name, case-insensitive.
    private static let interestingKeys: Set<String> = [
        "temperature", "virtualtemperature", "designcapacity", "applerawmaxcapacity",
        "applerawcurrentcapacity", "nominalchargecapacity", "fullchargecapacity",
        "cyclecount", "designcyclecount9c", "manufacturedate", "mfgdata",
        "manufacturerdata", "voltage", "applerawbatteryvoltage", "amperage", "instantamperage",
        "ischarging", "externalconnected", "fullycharged", "stateofcharge", "currentcapacity",
        "maxcapacity", "qmax", "cellvoltage", "cellcurrent", "weightedra", "notchargingreason",
        "slowchargingreason", "chargerinhibitreason", "chargerhwilimbackoffreason",
        "systempowerin", "systemload", "batterypower", "ipdinputpower", "ipdchargingallowed",
        "adaptervoltage", "current", "watts", "name", "serial", "devicename",
        "maximumchargecurrent", "maximumdischargecurrent", "permanentfailurestatus",
    ]

    private var filtered: [RawEntry] {
        var result = entries
        if onlyInteresting {
            result = result.filter { Self.interestingKeys.contains($0.key.lowercased()) }
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            result = result.filter { entry in
                entry.pathString.localizedCaseInsensitiveContains(trimmed)
                    || entry.value.localizedCaseInsensitiveContains(trimmed)
            }
        }
        return result
    }

    private var grouped: [(node: String, entries: [RawEntry])] {
        Dictionary(grouping: filtered, by: \.nodeClass)
            .map { (node: $0.key, entries: $0.value.sorted { $0.keyPath < $1.keyPath }) }
            .sorted { $0.node < $1.node }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controls
            if entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("没有读到注册表数据。此设备可能没有内置电池。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .onAppear(perform: rebuild)
        .onReceive(refreshTimer) { _ in rebuild() }
    }

    private func rebuild() {
        entries = monitor.snapshot?.registryTree?.flattened() ?? []
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("搜索键名或值（例如 Temperature、DesignCapacity、8694）", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
            .frame(maxWidth: 460)

            Toggle("只显示关键键", isOn: $onlyInteresting)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))

            Spacer()

            Text("\(filtered.count) / \(entries.count) 个键 · 已展开嵌套字典")
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(.tertiary)

            Button {
                copy(filtered)
            } label: {
                Label("复制结果", systemImage: "doc.on.doc")
            }
            .controlSize(.small)

            if let copyConfirmation {
                Text(copyConfirmation)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.charging)
            }
        }
    }

    private var table: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(grouped, id: \.node) { group in
                    nodeHeader(group.node, count: group.entries.count)
                    ForEach(group.entries) { entry in
                        row(entry)
                        Divider().opacity(0.35)
                    }
                    Color.clear.frame(height: 10)
                }
            }
            .padding(.vertical, 2)
        }
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private func nodeHeader(_ node: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "cpu")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Theme.seriesCapacity)
            Text(node)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
            Text("\(count) 个键")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.06))
    }

    private func row(_ entry: RawEntry) -> some View {
        HStack(spacing: 10) {
            Text(entry.keyPath)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 300, alignment: .leading)

            Text(entry.typeName)
                .font(.system(size: 9))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
                .foregroundStyle(.secondary)
                .frame(width: 68, alignment: .leading)

            Spacer(minLength: 8)

            Text(entry.value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button("复制键路径") { copyString(entry.pathString) }
            Button("复制值") { copyString(entry.value) }
            Button("复制 “路径 = 值”") { copyString("\(entry.pathString) = \(entry.value)") }
        }
    }

    // MARK: - Copy

    private func copy(_ entries: [RawEntry]) {
        let text = entries.map { "\($0.pathString) = \($0.value)" }.joined(separator: "\n")
        copyString(text)
        copyConfirmation = "已复制 \(entries.count) 行"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { copyConfirmation = nil }
    }

    private func copyString(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

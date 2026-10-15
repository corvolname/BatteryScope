import Foundation
import IOKit

/// A plain-Swift, fully detached copy of an IORegistry subtree.
///
/// Copying the whole subtree into Swift values (rather than handing around
/// `io_registry_entry_t` handles) means the reader never leaks kernel objects and the
/// captured data is safe to keep for the raw-key browser and history.
public struct RegistryNode {
    public let className: String
    public let properties: [String: Any]
    public let children: [RegistryNode]

    public init(className: String, properties: [String: Any], children: [RegistryNode]) {
        self.className = className
        self.properties = properties
        self.children = children
    }

    public func child(className name: String) -> RegistryNode? {
        children.first { $0.className == name }
    }

    public func children(className name: String) -> [RegistryNode] {
        children.filter { $0.className == name }
    }
}

public enum IORegistryTree {

    /// Capture the subtree rooted at the first service matching `serviceName`.
    /// `depth` limits how deep we walk (`0` = this node only).
    public static func capture(serviceName: String, depth: Int = 3) -> RegistryNode? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(serviceName))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return node(from: service, depth: depth)
    }

    /// Capture a subtree by raw entry, used for nested nodes such as `AppleChargerData`
    /// that are reachable but not matched by `IOServiceMatching` on every machine.
    private static func node(from entry: io_registry_entry_t, depth: Int) -> RegistryNode {
        var classBuffer = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(entry, &classBuffer)
        let className = String(cString: classBuffer)

        var properties: [String: Any] = [:]
        var unmanaged: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(entry, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let dict = unmanaged?.takeRetainedValue() as? [String: Any] {
            properties = dict
        }

        var children: [RegistryNode] = []
        if depth > 0 {
            var iterator: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(entry, kIOServicePlane, &iterator) == KERN_SUCCESS {
                defer { IOObjectRelease(iterator) }
                var child = IOIteratorNext(iterator)
                while child != 0 {
                    children.append(node(from: child, depth: depth - 1))
                    IOObjectRelease(child)
                    child = IOIteratorNext(iterator)
                }
            }
        }

        return RegistryNode(className: className, properties: properties, children: children)
    }
}

// MARK: - Flattening for the raw key browser

public struct RawEntry: Identifiable, Hashable {
    public let id: String          // full path, unique
    public let path: [String]      // ["AppleSmartBattery", "AppleSmartBatteryPack", "BatteryData", "Temperature"]
    public let nodeClass: String   // owning IORegistry node class
    public let keyPath: String     // path within the owning node: "BatteryData.Temperature"
    public let key: String
    public let value: String
    public let typeName: String

    public var pathString: String { path.joined(separator: ".") }
    public var displayPath: String { path.joined(separator: " › ") }
    public var depth: Int { path.count }

    public static func == (lhs: RawEntry, rhs: RawEntry) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension RegistryNode {

    /// Every scalar leaf in the subtree, flattened into searchable rows.
    /// Nested dictionaries are expanded (`BatteryData.DesignCapacity`) because that is
    /// exactly where the interesting battery values hide on Apple Silicon.
    public func flattened(prefix: [String] = []) -> [RawEntry] {
        var rows: [RawEntry] = []
        let base = prefix + [className]

        for key in properties.keys.sorted() {
            let value = properties[key]
            let type = ValueCoercion.typeName(of: value)
            if type == "Dictionary", let dict = ValueCoercion.dictionary(value) {
                rows.append(contentsOf: Self.expandDictionary(
                    dict, fullPath: base + [key], keyPath: [key], nodeClass: className))
            } else {
                rows.append(RawEntry(
                    id: (base + [key]).joined(separator: "."),
                    path: base + [key],
                    nodeClass: className,
                    keyPath: key,
                    key: key,
                    value: ValueCoercion.display(value),
                    typeName: type
                ))
            }
        }

        for child in children {
            rows.append(contentsOf: child.flattened(prefix: base))
        }
        return rows
    }

    private static func expandDictionary(_ dict: [String: Any],
                                         fullPath: [String],
                                         keyPath: [String],
                                         nodeClass: String) -> [RawEntry] {
        var rows: [RawEntry] = []
        for key in dict.keys.sorted() {
            let value = dict[key]
            let type = ValueCoercion.typeName(of: value)
            if type == "Dictionary", let nested = ValueCoercion.dictionary(value) {
                rows.append(contentsOf: expandDictionary(nested,
                                                         fullPath: fullPath + [key],
                                                         keyPath: keyPath + [key],
                                                         nodeClass: nodeClass))
            } else {
                rows.append(RawEntry(
                    id: (fullPath + [key]).joined(separator: "."),
                    path: fullPath + [key],
                    nodeClass: nodeClass,
                    keyPath: (keyPath + [key]).joined(separator: "."),
                    key: key,
                    value: ValueCoercion.display(value),
                    typeName: type
                ))
            }
        }
        return rows
    }

    /// Depth-first walk used by the tree view.
    public func allNodes() -> [RegistryNode] {
        [self] + children.flatMap { $0.allNodes() }
    }
}

// MARK: - Layered property lookup

/// Resolves a key across several dictionaries in priority order.
///
/// On Apple Silicon most interesting values live in `AppleSmartBatteryPack.BatteryData`,
/// on Intel Macs they sit at the top level of `AppleSmartBattery`. Layering lets one
/// reader serve both layouts without branching at every call site.
public struct LayeredProperties {
    private let layers: [[String: Any]]

    public init(_ layers: [[String: Any]]) {
        self.layers = layers.filter { !$0.isEmpty }
    }

    public func raw(_ key: String) -> Any? {
        for layer in layers {
            if let value = layer[key] { return value }
        }
        return nil
    }

    public func int(_ key: String) -> Int? { ValueCoercion.int(raw(key)) }
    public func uint64(_ key: String) -> UInt64? { ValueCoercion.uint64(raw(key)) }
    public func double(_ key: String) -> Double? { ValueCoercion.double(raw(key)) }
    public func bool(_ key: String) -> Bool? { ValueCoercion.bool(raw(key)) }
    public func string(_ key: String) -> String? { ValueCoercion.string(raw(key)) }
    public func dict(_ key: String) -> [String: Any]? { ValueCoercion.dictionary(raw(key)) }
    public func array(_ key: String) -> [Any]? { ValueCoercion.array(raw(key)) }
    public func data(_ key: String) -> Data? { ValueCoercion.data(raw(key)) }

    /// First non-nil result across the given keys, in the order supplied.
    public func firstInt(_ keys: [String]) -> Int? {
        for key in keys { if let v = int(key) { return v } }
        return nil
    }

    public func firstString(_ keys: [String]) -> String? {
        for key in keys { if let v = string(key) { return v } }
        return nil
    }

    /// A registry "unknown" sentinel is 65535 for minute counts; treat it as absent.
    public func minutes(_ key: String) -> Int? {
        guard let v = int(key), v >= 0, v != 65535 else { return nil }
        return v
    }
}

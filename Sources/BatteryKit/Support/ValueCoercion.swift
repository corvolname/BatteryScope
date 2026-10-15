import Foundation

/// IOKit hands back a grab-bag of CoreFoundation types. These helpers normalise them
/// into Swift values without ever trapping, and they report the *original* CF type name
/// so the raw-registry browser can show what the kernel actually published.
public enum ValueCoercion {

    // MARK: - Type reporting

    /// Human readable name for the underlying CoreFoundation/Swift type.
    ///
    /// Takes `Any?` deliberately: several call sites read straight out of a
    /// `[String: Any]` and would otherwise implicitly box the `Optional` into `Any`,
    /// making the dynamic type `Optional<Dictionary<...>>` and silently preventing nested
    /// battery dictionaries from being recognised and expanded.
    ///
    /// IOKit values arrive as `__NSCFNumber` / `__NSCFBoolean` / `__NSDictionaryM` while
    /// values built in Swift are `Dictionary<String, Any>` / `Array<Any>` / `Int`, so the
    /// checks below match both spellings.
    public static func typeName(of value: Any?) -> String {
        guard let value else { return "nil" }
        let raw = String(describing: type(of: value))

        // Container checks first: "Dictionary<String, Any>" also contains "String".
        if raw.contains("Dictionary") { return "Dictionary" }
        if raw.contains("Array") { return "Array" }
        if raw.contains("Boolean") { return "Boolean" }
        if raw.contains("Number") { return "Number" }
        if raw.contains("String") { return "String" }
        if raw.contains("Data") { return "Data" }

        switch raw {
        case "Int", "Int8", "Int16", "Int32", "Int64",
             "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "Double", "Float", "CGFloat":
            return "Number"
        default:
            return raw
        }
    }

    // MARK: - Scalars

    public static func int(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let n = value as? Int { return n }
        if let n = value as? Int64 { return Int(truncatingIfNeeded: n) }
        if let n = value as? Int32 { return Int(n) }
        if let n = value as? UInt64 { return Int(truncatingIfNeeded: n) }
        if let n = value as? UInt32 { return Int(n) }
        if let n = value as? Double { return Int(n) }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    /// Some registry values are printed by `ioreg` as huge unsigned numbers because the
    /// kernel stores them in an unsigned field. `NSNumber.uint64Value` reproduces that view.
    public static func uint64(_ value: Any?) -> UInt64? {
        guard let value else { return nil }
        if let n = value as? NSNumber { return n.uint64Value }
        if let n = value as? UInt64 { return n }
        if let s = value as? String { return UInt64(s) }
        return nil
    }

    public static func double(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let n = value as? Double { return n }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    public static func bool(_ value: Any?) -> Bool? {
        guard let value else { return nil }
        if let n = value as? NSNumber { return n.boolValue }
        if let b = value as? Bool { return b }
        if let s = value as? String {
            switch s.lowercased() {
            case "yes", "true", "1": return true
            case "no", "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    public static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let s = value as? String { return s }
        if let d = value as? Data { return d.hexString }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    // MARK: - Containers

    public static func dictionary(_ value: Any?) -> [String: Any]? {
        guard let value else { return nil }
        if let d = value as? [String: Any] { return d }
        if let d = value as? NSDictionary {
            var out: [String: Any] = [:]
            for (k, v) in d { if let key = k as? String { out[key] = v } }
            return out
        }
        return nil
    }

    public static func array(_ value: Any?) -> [Any]? {
        guard let value else { return nil }
        if let a = value as? [Any] { return a }
        if let a = value as? NSArray { return a.map { $0 } }
        return nil
    }

    public static func data(_ value: Any?) -> Data? {
        guard let value else { return nil }
        if let d = value as? Data { return d }
        if let d = value as? NSData { return d as Data }
        return nil
    }

    /// A stable, single-line rendering of any registry value, for tables and search.
    public static func display(_ value: Any?, maxLength: Int = 400) -> String {
        guard let value else { return "—" }
        switch typeName(of: value) {
        case "Boolean":
            return (bool(value) ?? false) ? "Yes" : "No"
        case "Data":
            let hex = (data(value) ?? Data()).hexString
            return truncate("0x" + hex, maxLength)
        case "Array":
            let items = array(value) ?? []
            let rendered = items.map { display($0, maxLength: 80) }.joined(separator: ", ")
            return truncate("[\(items.count)] \(rendered)", maxLength)
        case "Dictionary":
            let dict = dictionary(value) ?? [:]
            let rendered = dict.keys.sorted()
                .map { "\($0)=\(display(dict[$0], maxLength: 60))" }
                .joined(separator: ", ")
            return truncate("{\(dict.count)} \(rendered)", maxLength)
        default:
            return truncate(string(value) ?? String(describing: value), maxLength)
        }
    }

    private static func truncate(_ s: String, _ limit: Int) -> String {
        guard s.count > limit else { return s }
        return String(s.prefix(limit)) + "…"
    }
}

extension Data {
    public var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Big-endian ASCII interpretation, if every byte is printable.
    public var printableASCII: String? {
        guard !isEmpty else { return nil }
        let scalars = compactMap { Unicode.Scalar($0) }
        guard scalars.count == count else { return nil }
        let s = String(String.UnicodeScalarView(scalars))
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0.isPunctuation || $0 == " ") } ? s : nil
    }
}

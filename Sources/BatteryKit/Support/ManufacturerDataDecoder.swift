import Foundation

/// Decodes the packed `ManufacturerData` / `MfgData` blob published by the battery's
/// gas gauge (e.g. `bq40z651`).
///
/// Observed layout on a MacBookPro18,2 (Apple Silicon):
/// ```
/// 00 00 00 00 | 0b 00 | 01 00 | 0a 14 | 00 00 | 04 "1916" | 03 "002" | 03 "ATL" | 00 | ff ...
///  ^pack lot  ^fw      ^hw      ^cell rev        ^lot codes (length-prefixed ASCII)
/// ```
/// The last length-prefixed string is the cell vendor. macOS itself exposes neither the
/// vendor nor the lot codes in `system_profiler`, so this is genuinely extra information.
public struct ManufacturerData {
    public var packLotCode: UInt32?
    public var firmwareVersion: String?      // "0b00"
    public var hardwareRevision: String?     // "1.00"
    public var cellRevision: String?         // "0a14"
    public var lotCodes: [String] = []       // ["1916", "002"]
    public var vendorCode: String?           // "ATL"
    public var vendorName: String?           // "Amperex Technology Limited (ATL)"
    public var rawHex: String = ""

    public init() {}

    /// Tolerant parser: it walks length-prefixed ASCII runs from offset 12 and keeps
    /// whatever it finds, so an unexpected blob shape degrades to "less info" rather
    /// than wrong info.
    public static func decode(_ data: Data?) -> ManufacturerData? {
        guard let data, data.count >= 12 else { return nil }
        var result = ManufacturerData()
        result.rawHex = data.hexString

        let bytes = [UInt8](data)
        result.packLotCode = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        result.firmwareVersion = String(format: "%02x%02x", bytes[4], bytes[5])

        let hwMajor = bytes[6], hwMinor = bytes[7]
        result.hardwareRevision = hwMajor == 0 && hwMinor == 0
            ? String(format: "%02x%02x", hwMajor, hwMinor)
            : "\(hwMajor).\(String(format: "%02d", hwMinor))"
        result.cellRevision = String(format: "%02x%02x", bytes[8], bytes[9])

        var index = 12
        var runs: [String] = []
        while index < bytes.count {
            let length = Int(bytes[index])
            // 0x00 and 0xff are the terminators/padding seen in real dumps.
            if length == 0 || length == 0xff || index + 1 + length > bytes.count { break }
            let slice = bytes[(index + 1)..<(index + 1 + length)]
            guard slice.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) else { break }
            runs.append(String(decoding: slice, as: UTF8.self))
            index += 1 + length
        }

        if let vendor = runs.last {
            result.vendorCode = vendor
            result.vendorName = Self.vendorNames[vendor.uppercased()] ?? vendor
            result.lotCodes = Array(runs.dropLast())
        } else {
            result.lotCodes = runs
        }

        return result
    }

    /// Common Li-ion cell vendors used in Apple battery packs.
    private static let vendorNames: [String: String] = [
        "ATL": "Amperex Technology Limited (ATL)",
        "SDI": "Samsung SDI",
        "SEC": "Samsung SDI",
        "LGC": "LG Energy Solution",
        "LG": "LG Energy Solution",
        "MUR": "Murata Manufacturing",
        "MURATA": "Murata Manufacturing",
        "PAN": "Panasonic Energy",
        "PSE": "Panasonic Energy",
        "SWD": "Sunwoda Electronic",
        "DST": "Desay Battery",
        "COS": "Coslight Technology",
        "BAK": "BAK Battery",
        "EVE": "EVE Energy",
        "HY": "Highpower / HY",
        "TWS": "TWS Battery",
    ]
}

/// `ManufactureDate` as published by the gas gauge.
///
/// On this class of machine the value is *not* a Smart Battery packed date: a real dump
/// returns `0x383030313932`, i.e. the ASCII string `"800192"`. macOS never surfaces the
/// key (`system_profiler` omits a manufacture date entirely), so we decode what we can
/// and otherwise report the opaque code rather than invent a date.
public enum ManufactureDateDecoder {

    public enum Decoded {
        case smartBatteryDate(day: Int, month: Int, year: Int)
        case asciiCode(String)
        case opaque(UInt64)

        public var displayString: String {
            switch self {
            case let .smartBatteryDate(day, month, year):
                return String(format: "%04d-%02d-%02d", year, month, day)
            case let .asciiCode(code):
                return code
            case let .opaque(value):
                return "0x" + String(value, radix: 16, uppercase: true)
            }
        }

        public var isRealDate: Bool {
            if case .smartBatteryDate = self { return true }
            return false
        }
    }

    public static func decode(_ raw: UInt64?) -> Decoded? {
        guard let raw, raw != 0 else { return nil }

        // Smart Battery spec packing: bits 0-4 day, 5-8 month, 9-15 year since 1980.
        if raw <= 0xFFFF {
            let day = Int(raw & 0x1F)
            let month = Int((raw >> 5) & 0x0F)
            let year = 1980 + Int((raw >> 9) & 0x7F)
            if (1...31).contains(day), (1...12).contains(month), (2000...2100).contains(year) {
                return .smartBatteryDate(day: day, month: month, year: year)
            }
        }

        // ASCII-packed code, e.g. 0x383030313932 -> "800192".
        var bytes: [UInt8] = []
        var remaining = raw
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xFF), at: 0)
            remaining >>= 8
        }
        if bytes.count >= 4, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7f }) {
            return .asciiCode(String(decoding: bytes, as: UTF8.self))
        }

        return .opaque(raw)
    }
}

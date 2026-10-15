import Foundation
import IOKit

/// A working client for the System Management Controller.
///
/// ## Correction to an earlier conclusion
///
/// An earlier version of this project concluded that "the classic SMC keys are unusable on Apple
/// Silicon". **That was wrong, and it was my bug, not the platform's.** Two mistakes:
///
/// 1. `kSMCGetKeyInfo` must be called before `kSMCReadKey`, and the returned `dataSize`/`dataType`
///    echoed back in the read request.
/// 2. SMC data types are four characters and `flt` is really `"flt "` **with a trailing space**,
///    so an equality check against `"flt"` silently rejected every float key.
///
/// With those fixed, the classic keys answer `result = 0` and return sane values:
///
/// | Key | Meaning | Measured | Changes in 10 s |
/// |---|---|---|---|
/// | `PSTR` | system power | 24.7–29.9 W | 10 |
/// | `PDTR` | adapter/DC-in power | 32.3–37.3 W | 10 |
/// | `PPBR` | battery power | 1.64–1.67 W | 10 |
/// | `TB0T` | battery temperature | 34.9 °C | 2 |
/// | `F0Ac` | fan speed | 1507–1541 rpm | every sample |
///
/// So the SMC reports these about **once per second** — the genuinely live, directly measured,
/// correctly-scaled power source this app shows. (The keys that really are absent here are the
/// Intel-era charge-control keys `BCLM` / `CH0B` / `CH0C`, which return `result = 132`
/// = `kSMCKeyNotFound`; see the README on charge limiting.)
///
/// The structure of the interface is fixed by the driver: `IOServiceOpen("AppleSMC", type 0)`,
/// then `IOConnectCallStructMethod` with selector 2 and an 80-byte `SMCParamStruct`. The power
/// keys read through it (`PSTR` / `PDTR`, and `B0AC` × `B0AV` for the battery) are the ones that
/// refresh once per second.
public final class SMCClient {

    /// `SMCKeyData_t` is 80 bytes.
    private static let structSize = 80
    private static let offsetKey = 0
    private static let offsetKeySize = 28
    private static let offsetKeyType = 32
    private static let offsetKeyAttributes = 36
    private static let offsetResult = 40
    private static let offsetCommand = 42
    private static let offsetData32 = 44
    private static let offsetBytes = 48

    private static let commandReadBytes: UInt8 = 5
    private static let commandGetKeyFromIndex: UInt8 = 8
    private static let commandGetKeyInfo: UInt8 = 9
    private static let kernelIndexSMC: UInt32 = 2

    /// `kSMCKeyNotFound`
    public static let keyNotFound: UInt8 = 132

    private var connection: io_connect_t = 0
    private var infoCache: [String: KeyInfo] = [:]

    public struct KeyInfo: Hashable {
        public let dataSize: UInt32
        /// Trimmed four-character type, e.g. `flt`, `si16`, `sp78`.
        public let dataType: String
        public let attributes: UInt8
    }

    public init?() {
        var connection: io_connect_t = 0
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return nil }
        self.connection = connection
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    public var isOpen: Bool { connection != 0 }

    // MARK: - Protocol

    /// One `kSMCHandleYPCEvent` round trip. Returns the SMC's own `result` byte, where 0 is success.
    @discardableResult
    private func call(_ command: UInt8,
                      key: UInt32,
                      dataSize: UInt32 = 0,
                      dataType: UInt32 = 0,
                      data32: UInt32 = 0,
                      output: inout [UInt8]) -> UInt8 {
        var input = [UInt8](repeating: 0, count: Self.structSize)
        input.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            base.storeBytes(of: key.littleEndian, toByteOffset: Self.offsetKey, as: UInt32.self)
            base.storeBytes(of: dataSize.littleEndian, toByteOffset: Self.offsetKeySize, as: UInt32.self)
            base.storeBytes(of: dataType.littleEndian, toByteOffset: Self.offsetKeyType, as: UInt32.self)
            base.storeBytes(of: data32.littleEndian, toByteOffset: Self.offsetData32, as: UInt32.self)
            base.storeBytes(of: command, toByteOffset: Self.offsetCommand, as: UInt8.self)
        }
        output = [UInt8](repeating: 0, count: Self.structSize)
        var outputSize = Self.structSize
        let result = input.withUnsafeBytes { inputRaw in
            output.withUnsafeMutableBytes { outputRaw in
                IOConnectCallStructMethod(connection, Self.kernelIndexSMC,
                                          inputRaw.baseAddress, Self.structSize,
                                          outputRaw.baseAddress, &outputSize)
            }
        }
        guard result == KERN_SUCCESS, output.count >= Self.structSize else { return 0xFF }
        return output[Self.offsetResult]
    }

    private func fourCC(_ value: UInt32) -> String {
        let bytes = [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                     UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        return String(bytes: bytes, encoding: .ascii) ?? ""
    }

    private func code(_ name: String) -> UInt32 {
        var value: UInt32 = 0
        for byte in name.utf8.prefix(4) { value = (value << 8) | UInt32(byte) }
        return value
    }

    private func readUInt32(_ buffer: [UInt8], at offset: Int) -> UInt32 {
        buffer.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    // MARK: - Keys

    public func keyInfo(for name: String) -> KeyInfo? {
        if let cached = infoCache[name] { return cached }
        var output: [UInt8] = []
        let result = call(Self.commandGetKeyInfo, key: code(name), output: &output)
        guard result == 0 else { return nil }
        let info = KeyInfo(dataSize: readUInt32(output, at: Self.offsetKeySize),
                           dataType: fourCC(readUInt32(output, at: Self.offsetKeyType))
                            .trimmingCharacters(in: .whitespaces),
                           attributes: output[Self.offsetKeyAttributes])
        infoCache[name] = info
        return info
    }

    public func hasKey(_ name: String) -> Bool { keyInfo(for: name) != nil }

    /// Raw bytes of a key, or `nil` when the key is absent or unreadable.
    public func readBytes(_ name: String) -> [UInt8]? {
        guard let info = keyInfo(for: name) else { return nil }
        var output: [UInt8] = []
        let result = call(Self.commandReadBytes,
                          key: code(name),
                          dataSize: info.dataSize,
                          dataType: readTypeCode(info),
                          output: &output)
        guard result == 0, info.dataSize > 0, info.dataSize <= 32 else { return nil }
        return Array(output[Self.offsetBytes..<(Self.offsetBytes + Int(info.dataSize))])
    }

    private func readTypeCode(_ info: KeyInfo) -> UInt32 {
        // Re-derive the four-character type, padded back to four characters.
        let padded = info.dataType.padding(toLength: 4, withPad: " ", startingAt: 0)
        return code(padded)
    }

    /// Decodes a key into a number according to its SMC data type.
    public func readDouble(_ name: String) -> Double? {
        guard let info = keyInfo(for: name), let bytes = readBytes(name) else { return nil }
        return Self.decode(bytes, type: info.dataType)
    }

    /// Integer-typed convenience used for counters such as cycle count.
    public func readInt(_ name: String) -> Int? {
        readDouble(name).map { Int($0.rounded()) }
    }

    /// The SMC's own decoding rules, per data type.
    public static func decode(_ bytes: [UInt8], type: String) -> Double? {
        func unsigned<T: FixedWidthInteger>(_ type: T.Type) -> Double? {
            guard bytes.count >= MemoryLayout<T>.size else { return nil }
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: T.self) })
        }
        switch type {
        case "flt":
            guard bytes.count >= 4 else { return nil }
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Float32.self) })
        case "si16":
            guard bytes.count >= 2 else { return nil }
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int16.self) })
        case "ui16":
            return unsigned(UInt16.self)
        case "si8":
            guard let first = bytes.first else { return nil }
            return Double(Int8(bitPattern: first))
        case "ui8", "flag":
            guard let first = bytes.first else { return nil }
            return Double(first)
        case "ui32":
            return unsigned(UInt32.self)
        case "si32":
            guard bytes.count >= 4 else { return nil }
            return Double(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        case "sp78":
            // Signed 8.8 fixed point.
            guard bytes.count >= 2 else { return nil }
            let raw = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
            return Double(raw) / 256.0
        case "fp88", "fp8":
            guard bytes.count >= 2 else { return nil }
            let raw = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
            return Double(raw) / 256.0
        case "sp5a":
            guard bytes.count >= 2 else { return nil }
            let raw = bytes.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
            return Double(raw) / 1024.0
        default:
            return nil
        }
    }

    /// All keys the SMC will enumerate, by index.
    public func allKeyNames() -> [String] {
        var names: [String] = []
        for index in 0..<4096 {
            var output: [UInt8] = []
            let result = call(Self.commandGetKeyFromIndex, key: 0, data32: UInt32(index), output: &output)
            guard result == 0 else { break }
            let name = fourCC(readUInt32(output, at: Self.offsetKey))
            guard !name.isEmpty else { break }
            names.append(name)
        }
        return names
    }
}

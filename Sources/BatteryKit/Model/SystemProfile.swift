import Foundation

/// Static facts about the host, used for the card header and the detail window.
public struct SystemProfile {
    public var modelIdentifier: String
    public var modelMarketingName: String
    public var chipName: String
    public var physicalMemoryBytes: UInt64
    public var osVersion: String
    public var osBuild: String
    public var hostName: String

    public init(modelIdentifier: String,
                modelMarketingName: String,
                chipName: String,
                physicalMemoryBytes: UInt64,
                osVersion: String,
                osBuild: String,
                hostName: String) {
        self.modelIdentifier = modelIdentifier
        self.modelMarketingName = modelMarketingName
        self.chipName = chipName
        self.physicalMemoryBytes = physicalMemoryBytes
        self.osVersion = osVersion
        self.osBuild = osBuild
        self.hostName = hostName
    }

    public var memoryDescription: String {
        let gb = Double(physicalMemoryBytes) / 1_073_741_824
        return gb >= 1 ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb / 1.024)
    }

    public var osDescription: String { "macOS \(osVersion) (\(osBuild))" }
}

public enum SystemInfoReader {

    public static func read() -> SystemProfile {
        let model = sysctlString("hw.model") ?? "Mac"
        // `ProcessInfo.operatingSystemVersionString` is localised: on a Chinese system it reads
        // "版本 27.0.1 (版号 26A434)" — with full-width brackets — so parsing it produced
        // "macOS 版本 27.0.1 (版号 26A434) (26A434)". The numeric components are locale-neutral.
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return SystemProfile(
            modelIdentifier: model,
            modelMarketingName: marketingName(for: model),
            chipName: sysctlString("machdep.cpu.brand_string")
                ?? sysctlString("hw.chipname")
                ?? "Apple Silicon",
            physicalMemoryBytes: sysctlUInt64("hw.memsize") ?? 0,
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            osBuild: sysctlString("kern.osversion") ?? "—",
            hostName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlUInt64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    /// Best-effort mapping from board ID to a marketing name. Falls back to the raw
    /// identifier when unknown, which is what `system_profiler` also does.
    private static func marketingName(for identifier: String) -> String {
        marketingNames[identifier] ?? identifier
    }

    private static let marketingNames: [String: String] = [
        // Apple Silicon portables
        "MacBookPro18,1": "MacBook Pro 16-inch (2021, M1 Pro)",
        "MacBookPro18,2": "MacBook Pro 16-inch (2021, M1 Max)",
        "MacBookPro18,3": "MacBook Pro 14-inch (2021, M1 Pro)",
        "MacBookPro18,4": "MacBook Pro 14-inch (2021, M1 Max)",
        "MacBookPro17,1": "MacBook Pro 13-inch (M1, 2020)",
        "Mac14,5": "MacBook Pro 14-inch (2023, M2 Max)",
        "Mac14,6": "MacBook Pro 16-inch (2023, M2 Max)",
        "Mac14,9": "MacBook Pro 14-inch (2023, M2 Pro)",
        "Mac14,10": "MacBook Pro 16-inch (2023, M2 Pro)",
        "Mac15,3": "MacBook Pro 14-inch (2023, M3)",
        "Mac15,6": "MacBook Pro 14-inch (2023, M3 Pro)",
        "Mac15,7": "MacBook Pro 16-inch (2023, M3 Pro)",
        "Mac15,8": "MacBook Pro 14-inch (2023, M3 Max)",
        "Mac15,9": "MacBook Pro 16-inch (2023, M3 Max)",
        "Mac15,10": "MacBook Pro 14-inch (2023, M3 Max)",
        "Mac15,11": "MacBook Pro 16-inch (2023, M3 Max)",
        "Mac16,1": "MacBook Pro 14-inch (2024, M4)",
        "Mac16,5": "MacBook Pro 16-inch (2024, M4 Pro/Max)",
        "Mac16,6": "MacBook Pro 14-inch (2024, M4 Max)",
        "Mac16,7": "MacBook Pro 16-inch (2024, M4 Max)",
        "Mac16,8": "MacBook Pro 14-inch (2024, M4 Pro)",
        "MacBookAir10,1": "MacBook Air (M1, 2020)",
        "Mac14,2": "MacBook Air (M2, 2022)",
        "Mac14,15": "MacBook Air 15-inch (M2, 2023)",
        "Mac15,12": "MacBook Air 13-inch (M3, 2024)",
        "Mac15,13": "MacBook Air 15-inch (M3, 2024)",
        "Mac16,12": "MacBook Air 13-inch (M4, 2025)",
        "Mac16,13": "MacBook Air 15-inch (M4, 2025)",
        // Apple Silicon desktops (no battery, but kept for completeness)
        "Mac13,1": "Mac Studio (2022, M1 Max)",
        "Mac13,2": "Mac Studio (2022, M1 Ultra)",
        "Mac14,13": "Mac Studio (2023, M2 Max)",
        "Mac14,14": "Mac Studio (2023, M2 Ultra)",
        "Mac14,3": "Mac mini (2023, M2)",
        "Mac14,12": "Mac mini (2023, M2 Pro)",
        // Intel portables
        "MacBookPro16,1": "MacBook Pro 16-inch (2019)",
        "MacBookPro16,2": "MacBook Pro 13-inch (2020, four Thunderbolt 3)",
        "MacBookPro16,3": "MacBook Pro 13-inch (2020, two Thunderbolt 3)",
        "MacBookPro16,4": "MacBook Pro 16-inch (2019, Radeon 5600M)",
        "MacBookPro15,1": "MacBook Pro 15-inch (2018/2019)",
        "MacBookPro15,2": "MacBook Pro 13-inch (2018/2019)",
        "MacBookPro15,3": "MacBook Pro 15-inch (2018/2019, Vega)",
        "MacBookPro15,4": "MacBook Pro 13-inch (2019, two Thunderbolt 3)",
        "MacBookAir9,1": "MacBook Air (2020, Intel)",
        "MacBookAir8,1": "MacBook Air (2018)",
        "MacBookAir8,2": "MacBook Air (2019)",
    ]
}

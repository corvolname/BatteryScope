import Foundation
import IOKit

/// One live read of CPU / GPU / memory load.
///
/// These are the readings that move appreciably inside a single second, which is why they belong
/// beside the power figures on a live chart: measured on a MacBookPro18,2, GPU utilisation sat at
/// 31 % and CPU at 18 % while the machine was compiling, and both were different again a second
/// later. All three sources are public API — no SMC keys, no private IOKit.
public struct SystemLoadReading {
    /// Total CPU busy percentage (user + system), 0–100.
    public var cpuLoadPercent: Double?
    /// GPU "Device Utilization %", 0–100.
    public var gpuLoadPercent: Double?
    /// Memory in use in bytes, and the total installed.
    public var memoryUsedBytes: UInt64?
    public var memoryTotalBytes: UInt64?
    public var timestamp = Date()

    public init() {}

    public var memoryUsedPercent: Double? {
        guard let used = memoryUsedBytes, let total = memoryTotalBytes, total > 0 else { return nil }
        return Double(used) / Double(total) * 100
    }
}

public final class SystemLoadReader {

    /// Previous CPU tick counts. CPU load is a *difference* between two reads, so the first call
    /// after start has nothing to compare against and reports nil rather than inventing a value.
    private var previousTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    public init() {}

    public func read() -> SystemLoadReading {
        var reading = SystemLoadReading()
        reading.cpuLoadPercent = readCPULoad()
        reading.gpuLoadPercent = readGPULoad()
        if let memory = readMemory() {
            reading.memoryUsedBytes = memory.used
            reading.memoryTotalBytes = memory.total
        }
        return reading
    }

    // MARK: - CPU

    private func readCPULoad() -> Double? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_,
                          vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        let stride = Int(CPU_STATE_MAX)
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * stride
            user += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_USER)]))
            system += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_SYSTEM)]))
            idle += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_IDLE)]))
            nice += UInt64(UInt32(bitPattern: info[base + Int(CPU_STATE_NICE)]))
        }
        defer { previousTicks = (user, system, idle, nice) }
        guard let previous = previousTicks else { return nil }
        let deltaUser = user &- previous.user
        let deltaSystem = system &- previous.system
        let deltaIdle = idle &- previous.idle
        let deltaNice = nice &- previous.nice
        let total = deltaUser + deltaSystem + deltaIdle + deltaNice
        guard total > 0 else { return nil }
        return Double(deltaUser + deltaSystem + deltaNice) / Double(total) * 100
    }

    // MARK: - GPU

    /// `IOAccelerator` publishes utilisation counters in its `PerformanceStatistics` dictionary.
    private func readGPULoad() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  let statistics = dictionary["PerformanceStatistics"] as? [String: Any] else { continue }
            for key in ["Device Utilization %", "Renderer Utilization %"] {
                if let value = statistics[key] as? Int, value >= 0 {
                    let percent = Double(value)
                    if best == nil || percent > best! { best = percent }
                    break
                }
            }
        }
        return best
    }

    // MARK: - Memory

    private func readMemory() -> (used: UInt64, total: UInt64)? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let pageSize = UInt64(vm_kernel_page_size)
        // Wired + active + compressed is what Activity Monitor calls "Memory Used".
        let used = (UInt64(stats.wire_count)
                    + UInt64(stats.active_count)
                    + UInt64(stats.compressor_page_count)) * pageSize
        return (used, ProcessInfo.processInfo.physicalMemory)
    }
}

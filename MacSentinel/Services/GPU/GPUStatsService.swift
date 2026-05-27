//
//  GPUStatsService.swift
//  MacSentinel
//
//  Read GPU utilisation and VRAM via:
//    • IORegistry (`IOAccelerator` class) — Device Utilization % + In-Use VRAM
//      (Apple Silicon AGX / Intel Iris / discrete eGPU all expose this)
//    • Metal MTLDevice.recommendedMaxWorkingSetSize  — VRAM budget
//
//  No private API, no entitlement, no sudo. Returns nil on failure.
//

import Foundation
import IOKit
import Metal

struct GPUStats: Hashable {
    /// GPU name as reported by Metal (e.g. "Apple M2 Pro").
    var deviceName: String
    /// 0–100 instantaneous GPU usage. -1 if unavailable.
    var devicePercent: Double
    /// Currently in-use VRAM in bytes.
    var vramUsedBytes: UInt64
    /// Metal's recommended max working set (VRAM budget) in bytes.
    var vramBudgetBytes: UInt64
    /// Whether this device is "low power" (integrated) — Apple Silicon: always integrated.
    var isLowPower: Bool

    var vramUsagePercent: Double {
        guard vramBudgetBytes > 0 else { return 0 }
        return Double(vramUsedBytes) / Double(vramBudgetBytes) * 100
    }
}

enum GPUStatsService {

    /// One-shot snapshot. Concurrent-safe (returns its own copy).
    static func snapshot() async -> [GPUStats] {
        await Task.detached(priority: .utility) {
            collect()
        }.value
    }

    private static func collect() -> [GPUStats] {
        var results: [GPUStats] = []
        let metalDevices = MTLCopyAllDevices()
        let acceleratorEntries = ioregEntries(matching: "IOAccelerator")

        for device in metalDevices {
            let name = device.name
            let budget = UInt64(device.recommendedMaxWorkingSetSize)
            // Best-effort match by name to an IOAccelerator entry
            let entry = acceleratorEntries.first { ioName($0).contains(name)
                || name.contains(ioName($0)) }
            let perf = entry.flatMap { perfStats(for: $0) }
            results.append(GPUStats(
                deviceName: name,
                devicePercent: perf?.devicePercent ?? -1,
                vramUsedBytes: perf?.vramInUse ?? 0,
                vramBudgetBytes: budget,
                isLowPower: device.isLowPower
            ))
        }
        // Release the IOServiceObjects we copied
        for e in acceleratorEntries { IOObjectRelease(e) }
        return results
    }

    // MARK: - IORegistry plumbing

    private struct PerfStats { var devicePercent: Double; var vramInUse: UInt64 }

    private static func ioregEntries(matching className: String) -> [io_service_t] {
        var iter: io_iterator_t = 0
        let match = IOServiceMatching(className)
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS else {
            return []
        }
        var list: [io_service_t] = []
        while case let entry = IOIteratorNext(iter), entry != 0 {
            list.append(entry)
        }
        IOObjectRelease(iter)
        return list
    }

    private static func ioName(_ entry: io_service_t) -> String {
        var name: [CChar] = Array(repeating: 0, count: 128)
        _ = IORegistryEntryGetName(entry, &name)
        return String(cString: name)
    }

    /// Pull the PerformanceStatistics dictionary, extract "Device Utilization %"
    /// and "In use system memory" (or "vramFreeBytes" — fall back).
    private static func perfStats(for entry: io_service_t) -> PerfStats? {
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0)
            == KERN_SUCCESS else { return nil }
        guard let dict = properties?.takeRetainedValue() as? [String: Any] else { return nil }
        guard let perf = dict["PerformanceStatistics"] as? [String: Any] else { return nil }

        let utilKeys = ["Device Utilization %", "GPU Activity(%)", "GPU Activity"]
        let vramUseKeys = ["In use system memory", "vramUsedBytes", "vramBytes",
                           "Alloc system memory"]

        var util: Double = -1
        for k in utilKeys {
            if let v = perf[k] as? NSNumber { util = v.doubleValue; break }
        }
        var vram: UInt64 = 0
        for k in vramUseKeys {
            if let v = perf[k] as? NSNumber { vram = v.uint64Value; break }
        }
        return PerfStats(devicePercent: util, vramInUse: vram)
    }
}

//
//  BatteryHealthService.swift
//  MacSentinel
//
//  Pulls additional battery hardware metrics that are NOT in
//  SystemDataCollector's per-tick BatterySnapshot. Used by the battery
//  drill-down detail view.
//
//  Source of truth: `ioreg -r -c AppleSmartBattery -d 1` (same data that
//  coconutBattery consumes). Run once on demand — these fields rarely
//  change during a session, so we don't need timer-driven sampling.
//

import Foundation

/// Static-ish hardware facts that complement the per-tick BatterySnapshot.
struct BatteryHardwareInfo {
    /// Designed full-charge capacity in mAh (battery's rated maximum).
    var designCapacityMAh: Int
    /// Current measured maximum capacity in mAh (degrades over time).
    var currentMaxCapacityMAh: Int
    /// Estimated minutes until empty (discharging) or until full (charging).
    /// `nil` when macOS reports the sentinel 65535 (still calculating).
    var timeRemainingMinutes: Int?
    /// Connected power adapter wattage. `nil` when on battery.
    var adapterWatts: Int?
    /// Power adapter description (e.g. "pd charger", "usb power adapter").
    var adapterDescription: String?
    /// Battery controller chip identifier (e.g. "bq40z651").
    var controllerDeviceName: String?

    /// Health percent computed from raw capacities (more precise than
    /// SnapshotBattery.healthPercent which floors to integer).
    var preciseHealthPercent: Double {
        guard designCapacityMAh > 0 else { return 0 }
        return Double(currentMaxCapacityMAh) / Double(designCapacityMAh) * 100
    }
}

enum BatteryHealthService {

    /// Read AppleSmartBattery once. Returns nil on desktop Macs / failure.
    static func fetch() async -> BatteryHardwareInfo? {
        await Task.detached(priority: .utility) {
            runIoreg()
        }.value
    }

    // MARK: - Implementation

    private static func runIoreg() -> BatteryHardwareInfo? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-r", "-c", "AppleSmartBattery", "-d", "1"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { return nil }

        // Parse line-based "key" = value pairs from ioreg output
        return parse(text)
    }

    private static func parse(_ text: String) -> BatteryHardwareInfo? {
        let designCapacity = extractInt(text, key: "DesignCapacity") ?? 0
        let appleRawMax    = extractInt(text, key: "AppleRawMaxCapacity") ?? 0
        guard designCapacity > 0 || appleRawMax > 0 else { return nil }

        let timeRemainingRaw = extractInt(text, key: "TimeRemaining")
        let timeRemaining: Int? = {
            guard let raw = timeRemainingRaw, raw > 0, raw < 65535 else { return nil }
            return raw
        }()

        // AdapterDetails block: {"...","Watts"=15,...,"Description"="pd charger",...}
        let adapterWatts       = extractAdapterField(text, field: "Watts")
        let adapterDescription = extractAdapterFieldString(text, field: "Description")

        let deviceName = extractString(text, key: "DeviceName")

        return BatteryHardwareInfo(
            designCapacityMAh: designCapacity,
            currentMaxCapacityMAh: appleRawMax,
            timeRemainingMinutes: timeRemaining,
            adapterWatts: adapterWatts,
            adapterDescription: adapterDescription,
            controllerDeviceName: deviceName
        )
    }

    private static func extractInt(_ text: String, key: String) -> Int? {
        // matches  "Key" = 12345
        guard let range = text.range(
            of: "\"\(key)\"\\s*=\\s*([0-9]+)",
            options: .regularExpression
        ) else { return nil }
        let match = String(text[range])
        return Int(match.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? "")
    }

    private static func extractString(_ text: String, key: String) -> String? {
        guard let range = text.range(
            of: "\"\(key)\"\\s*=\\s*\"([^\"]+)\"",
            options: .regularExpression
        ) else { return nil }
        let match = String(text[range])
        // value between first and last quote of the RHS
        let parts = match.split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }

    private static func extractAdapterField(_ text: String, field: String) -> Int? {
        guard let range = text.range(of: "\"AdapterDetails\"\\s*=\\s*\\{[^}]*\\}",
                                     options: .regularExpression) else { return nil }
        let block = String(text[range])
        return extractInt(block, key: field)
    }

    private static func extractAdapterFieldString(_ text: String, field: String) -> String? {
        guard let range = text.range(of: "\"AdapterDetails\"\\s*=\\s*\\{[^}]*\\}",
                                     options: .regularExpression) else { return nil }
        let block = String(text[range])
        return extractString(block, key: field)
    }
}

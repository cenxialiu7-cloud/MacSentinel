import Foundation

// MARK: - ScanHistoryService
//
// Persists scan summaries to disk so the UI can show "Before / After"
// deltas to the user. Each summary captures top-line metrics from
// migration + cache scans.
//
// On-disk format: JSON Lines at
//   ~/Library/Application Support/MacSentinel/scan_history.jsonl
// Up to 50 entries are kept (oldest dropped).

struct ScanHistoryEntry: Codable {
    let timestamp: Date

    // Migration scan metrics
    var orphanedContainerCount: Int = 0
    var orphanedContainerBytes: UInt64 = 0
    var orphanedLaunchAgentCount: Int = 0
    var legacyKextCount: Int = 0
    var rosettaAppCount: Int = 0

    // Cache scan metrics
    var totalCacheBytes: UInt64 = 0
    var cacheCategoryCount: Int = 0

    // Disk
    var diskFreeBytes: UInt64 = 0
}

enum ScanHistoryService {

    private static let maxEntries = 50

    static var historyURL: URL {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacSentinel", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport, withIntermediateDirectories: true)
        return appSupport.appendingPathComponent("scan_history.jsonl")
    }

    /// Append a new entry to history (JSON Lines).
    static func append(_ entry: ScanHistoryEntry) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let line = try encoder.encode(entry)
        var data = line
        data.append(0x0A)  // newline

        if !FileManager.default.fileExists(atPath: historyURL.path) {
            FileManager.default.createFile(atPath: historyURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: historyURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        }
        trimIfNeeded()
    }

    /// Read all entries (oldest first).
    static func readAll() -> [ScanHistoryEntry] {
        guard let data = try? Data(contentsOf: historyURL),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            try? decoder.decode(ScanHistoryEntry.self, from: Data(line.utf8))
        }
    }

    /// Latest entry, or nil if no history.
    static func latest() -> ScanHistoryEntry? { readAll().last }

    /// Second-most-recent entry (used as "before" baseline).
    static func previous() -> ScanHistoryEntry? {
        let all = readAll()
        return all.count >= 2 ? all[all.count - 2] : nil
    }

    /// Calculate delta between latest and previous.
    static func latestDelta() -> ScanHistoryDelta? {
        guard let current = latest(), let prev = previous() else { return nil }
        return ScanHistoryDelta(before: prev, after: current)
    }

    private static func trimIfNeeded() {
        let all = readAll()
        if all.count > maxEntries {
            let trimmed = Array(all.suffix(maxEntries))
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var output = Data()
            for entry in trimmed {
                if let data = try? encoder.encode(entry) {
                    output.append(data)
                    output.append(0x0A)
                }
            }
            try? output.write(to: historyURL, options: .atomic)
        }
    }
}

// MARK: - Delta

struct ScanHistoryDelta {
    let before: ScanHistoryEntry
    let after: ScanHistoryEntry

    var orphanContainerCountDelta: Int { after.orphanedContainerCount - before.orphanedContainerCount }
    var orphanContainerBytesDelta: Int64 {
        Int64(after.orphanedContainerBytes) - Int64(before.orphanedContainerBytes)
    }
    var launchAgentDelta: Int { after.orphanedLaunchAgentCount - before.orphanedLaunchAgentCount }
    var kextDelta: Int { after.legacyKextCount - before.legacyKextCount }
    var rosettaAppDelta: Int { after.rosettaAppCount - before.rosettaAppCount }
    var diskFreeDelta: Int64 { Int64(after.diskFreeBytes) - Int64(before.diskFreeBytes) }

    var timeBetween: TimeInterval {
        after.timestamp.timeIntervalSince(before.timestamp)
    }
}

import Foundation
import os.log

// MARK: - Audit Log (JSON Lines format)
//
// Each entry is a single JSON object on its own line:
//   {"ts":"2026-05-23T10:00:00Z","action":"DELETE","caller":"gui","details":{...}}
//
// Designed to be tail-friendly and easily consumed by AI assistants /
// log-shipping tools. The file is bounded to maxEntries lines via trim.

actor AuditLog {

    static let shared = AuditLog()

    nonisolated let logURL: URL
    private let maxEntries = 1000
    private let logger = Logger(subsystem: "com.macsentinel.app", category: "AuditLog")

    private init() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacSentinel", isDirectory: true)
        try? FileManager.default.createDirectory(at: appSupport,
                                                  withIntermediateDirectories: true)
        logURL = appSupport.appendingPathComponent("audit.jsonl")
    }

    // ── Action enum — wire format constants ─────────────────────────────
    enum Action {
        case deletion(url: URL, sizeBytes: UInt64)
        case bulkDeletion(paths: [String], totalBytes: UInt64, caller: String)
        case processKill(pid: Int32, name: String, caller: String)
        case launchAgentDisabled(label: String, plistPath: String)
        case scanCompleted(type: String, itemsFound: Int, totalBytes: UInt64)
        case configChanged(key: String, newValue: String, caller: String)

        /// Action verb stored in the log
        var verb: String {
            switch self {
            case .deletion:              return "DELETE"
            case .bulkDeletion:          return "BULK_DELETE"
            case .processKill:           return "KILL"
            case .launchAgentDisabled:   return "DISABLE_LAUNCH_AGENT"
            case .scanCompleted:         return "SCAN_COMPLETE"
            case .configChanged:         return "CONFIG_CHANGED"
            }
        }

        /// Caller tag — who initiated this operation
        var caller: String {
            switch self {
            case .bulkDeletion(_, _, let c), .processKill(_, _, let c),
                 .configChanged(_, _, let c):
                return c
            default:
                return "gui"
            }
        }

        /// Structured details payload (encoded as nested JSON object)
        var detailsJSON: [String: Any] {
            switch self {
            case .deletion(let url, let size):
                return ["path": url.path, "sizeBytes": size]
            case .bulkDeletion(let paths, let bytes, _):
                return ["count": paths.count, "totalBytes": bytes, "firstPath": paths.first ?? ""]
            case .processKill(let pid, let name, _):
                return ["pid": Int(pid), "processName": name]
            case .launchAgentDisabled(let label, let path):
                return ["label": label, "plistPath": path]
            case .scanCompleted(let type, let count, let bytes):
                return ["scanType": type, "itemsFound": count, "totalBytes": bytes]
            case .configChanged(let key, let value, _):
                return ["key": key, "newValue": value]
            }
        }

        /// Encode this action as a single JSON line.
        func encodeJSONLine() throws -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            let entry: [String: Any] = [
                "ts":      formatter.string(from: Date()),
                "action":  verb,
                "caller":  caller,
                "details": detailsJSON,
            ]
            let data = try JSONSerialization.data(withJSONObject: entry,
                                                   options: [.sortedKeys])
            return (String(data: data, encoding: .utf8) ?? "{}") + "\n"
        }
    }

    // MARK: - Record

    func record(_ action: Action) {
        do {
            let line = try action.encodeJSONLine()
            logger.info("\(line)")

            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                handle.seekToEndOfFile()
                if let data = line.data(using: .utf8) { handle.write(data) }
                try? handle.close()
            }
            trimIfNeeded()
        } catch {
            logger.error("Failed to encode audit entry: \(error.localizedDescription)")
        }
    }

    func readAll() -> [String] {
        guard let content = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        return content.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    /// Decode the last N entries back into [String: Any] dictionaries.
    /// Useful for the MCP read_audit_log tool.
    func readRecent(limit: Int = 50) -> [[String: Any]] {
        let lines = readAll().suffix(limit)
        return lines.compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }
    }

    private func trimIfNeeded() {
        var lines = readAll()
        if lines.count > maxEntries {
            lines = Array(lines.suffix(maxEntries))
            let trimmed = lines.joined(separator: "\n") + "\n"
            try? trimmed.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
}

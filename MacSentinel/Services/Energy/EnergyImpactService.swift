//
//  EnergyImpactService.swift
//  MacSentinel
//
//  Spawns `powermetrics --samplers tasks -i N -n 1` via osascript admin
//  (powermetrics requires root) to get per-process Energy Impact ratings,
//  identical to what System Settings → Battery shows.
//
//  Strategy:
//    1. User-triggered (not automatic) — admin prompt is intrusive.
//    2. One-shot 1-second sample, parse stdout, return top N processes.
//

import Foundation

/// One per-process energy reading.
struct EnergyImpactRow: Identifiable, Hashable {
    let id: Int32           // PID
    let name: String
    let energyImpact: Double
    let cpuMsPerSec: Double
    let userActivity: Double
}

enum EnergyImpactService {

    enum EnergyError: Error, LocalizedError {
        case cancelled
        case scriptFailed(String)
        case noOutput
        var errorDescription: String? {
            switch self {
            case .cancelled:           return "已取消（未輸入管理員密碼）。"
            case .scriptFailed(let m): return "powermetrics 失敗：\(m)"
            case .noOutput:            return "powermetrics 沒有輸出（macOS 可能限制此 sampler）。"
            }
        }
    }

    /// Run powermetrics --samplers tasks with admin privileges. Returns Top N
    /// processes sorted by Energy Impact, or an EnergyError.
    static func sample(topN: Int = 10) async -> Result<[EnergyImpactRow], EnergyError> {
        await Task.detached(priority: .userInitiated) {
            // Build the shell command. -i 1000 -n 1 = single 1-second sample.
            // --show-process-coalition adds the grouped energy column.
            let shellCmd = "/usr/bin/powermetrics --samplers tasks -i 1000 -n 1 2>/dev/null"
            let escaped = shellCmd.replacingOccurrences(of: "\"", with: "\\\"")
            let script = "do shell script \"\(escaped)\" with administrator privileges"

            var err: NSDictionary?
            let result = NSAppleScript(source: script)?.executeAndReturnError(&err)

            if let err = err {
                if (err["NSAppleScriptErrorNumber"] as? Int) == -128 {
                    return .failure(EnergyError.cancelled)
                }
                let msg = err["NSAppleScriptErrorMessage"] as? String ?? "未知錯誤"
                return .failure(EnergyError.scriptFailed(msg))
            }
            guard let text = result?.stringValue, !text.isEmpty else {
                return .failure(EnergyError.noOutput)
            }
            let rows = parse(output: text)
            let sorted = rows.sorted { $0.energyImpact > $1.energyImpact }
            return .success(Array(sorted.prefix(topN)))
        }.value
    }

    // MARK: - Parser

    /// Powermetrics tasks output looks like:
    ///   Name              ID     CPU ms/s  energy  ...
    ///   kernel_task       0      178.20    142.11
    ///   WindowServer      214    32.81     21.40
    /// We locate the "energy" column header and parse subsequent rows.
    private static func parse(output: String) -> [EnergyImpactRow] {
        var rows: [EnergyImpactRow] = []
        let lines = output.components(separatedBy: .newlines)

        // Find header line with column positions
        var nameIdx = -1, idIdx = -1, cpuIdx = -1, energyIdx = -1
        var inTaskBlock = false

        for raw in lines {
            let line = raw

            if !inTaskBlock {
                // Look for header row containing both "Name" and "energy"
                if line.contains("Name") && line.lowercased().contains("energy") {
                    let cols = line.split(separator: " ", omittingEmptySubsequences: true)
                        .map(String.init)
                    nameIdx   = cols.firstIndex(of: "Name") ?? 0
                    idIdx     = cols.firstIndex(of: "ID") ?? 1
                    cpuIdx    = cols.firstIndex(where: { $0.lowercased().contains("cpu") }) ?? 2
                    energyIdx = cols.firstIndex(where: { $0.lowercased() == "energy" }) ?? 4
                    inTaskBlock = true
                    continue
                }
                continue
            }

            // End of task block: empty line or new section
            if line.trimmingCharacters(in: .whitespaces).isEmpty { inTaskBlock = false; continue }
            if line.hasPrefix("*") || line.hasPrefix("=") { inTaskBlock = false; continue }

            // Split on whitespace; powermetrics is fixed-width-ish but
            // splits on multiple spaces are good enough here.
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            guard parts.count > max(nameIdx, max(idIdx, max(cpuIdx, energyIdx))) else { continue }

            let name   = parts[nameIdx]
            guard let pid = Int32(parts[idIdx]) else { continue }
            let cpuMs  = Double(parts[cpuIdx]) ?? 0
            let energy = Double(parts[energyIdx]) ?? 0

            rows.append(EnergyImpactRow(
                id: pid, name: name,
                energyImpact: energy,
                cpuMsPerSec: cpuMs,
                userActivity: 0
            ))
        }
        return rows
    }
}

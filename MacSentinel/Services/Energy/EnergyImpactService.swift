//
//  EnergyImpactService.swift
//  MacSentinel
//
//  Run `powermetrics --samplers tasks --show-process-energy` as root via
//  `osascript ... administrator privileges`, capture output to a temp file
//  (NOT via AppleScript's `result` string — that has a ~16 KB cap and
//  silently truncates large powermetrics dumps), then parse.
//
//  Returns per-process Energy Impact + CPU ms/s. If the platform / macOS
//  version no longer exposes the Energy column at all, the service returns
//  a friendly "unavailable" Result so the view can suppress the section.
//

import Foundation

/// One per-process energy reading.
struct EnergyImpactRow: Identifiable, Hashable {
    let id: Int32
    let name: String
    let energyImpact: Double      // Apple's composite Energy Impact metric
    let cpuMsPerSec: Double
}

enum EnergyImpactService {

    enum EnergyError: Error, LocalizedError {
        case cancelled
        case scriptFailed(String)
        case noOutput
        case noEnergyColumn      // macOS version doesn't expose the column
        var errorDescription: String? {
            switch self {
            case .cancelled:           return "已取消（未輸入管理員密碼）。"
            case .scriptFailed(let m): return "powermetrics 失敗：\(m)"
            case .noOutput:            return "powermetrics 沒有輸出（macOS 可能限制此 sampler）。"
            case .noEnergyColumn:
                return "此版本 macOS 的 powermetrics 不再提供 Energy Impact 欄位。請改至「系統設定 → 電池 → 過去 24 小時」查看。"
            }
        }
    }

    static func sample(topN: Int = 10) async -> Result<[EnergyImpactRow], EnergyError> {
        await Task.detached(priority: .userInitiated) {
            // 1. Pick a temp file path; powermetrics writes the full dump
            //    there so we don't have to worry about AppleScript's
            //    ~16 KB return-string cap (which silently truncates).
            let tmpPath = NSTemporaryDirectory()
                + "macsentinel-pm-\(UUID().uuidString).txt"

            // 2. Build the shell command. `--show-process-energy` enables the
            //    energy column (same metric Activity Monitor's Energy tab
            //    shows). `-i 1000 -n 1` = single 1-second sample.
            let shellCmd = """
            /usr/bin/powermetrics \
            --samplers tasks --show-process-energy \
            -i 1000 -n 1 > '\(tmpPath)' 2>&1
            """
            let escaped = shellCmd
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let script = "do shell script \"\(escaped)\" with administrator privileges"

            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            defer { try? FileManager.default.removeItem(atPath: tmpPath) }

            if let err = err {
                if (err["NSAppleScriptErrorNumber"] as? Int) == -128 {
                    return .failure(EnergyError.cancelled)
                }
                let msg = err["NSAppleScriptErrorMessage"] as? String ?? "未知錯誤"
                return .failure(EnergyError.scriptFailed(msg))
            }

            guard let data = FileManager.default.contents(atPath: tmpPath),
                  let text = String(data: data, encoding: .utf8),
                  !text.isEmpty else {
                return .failure(EnergyError.noOutput)
            }

            let parsed = parse(output: text)
            guard !parsed.isEmpty else {
                // We got powermetrics output but couldn't find the energy
                // column — likely this macOS version dropped it.
                return .failure(EnergyError.noEnergyColumn)
            }
            let sorted = parsed.sorted { $0.energyImpact > $1.energyImpact }
            return .success(Array(sorted.prefix(topN)))
        }.value
    }

    // MARK: - Parser

    /// powermetrics output has multiple sections separated by `***`. We only
    /// need the "Running tasks" table. Layout (with --show-process-energy):
    ///
    ///   Name                      ID    CPU ms/s  User%  Deadlines ...  Wakeups ...  GPU ms/s  Energy Impact
    ///   kernel_task               0     178.21    0.00   0              0            0.00      0.0
    ///   WindowServer              214   32.81     74.71  0              0            0.00      24.7
    ///
    /// We locate the energy column dynamically (header name "Energy Impact"
    /// is the canonical form on modern macOS, but we also accept variants).
    private static func parse(output: String) -> [EnergyImpactRow] {
        let lines = output.components(separatedBy: .newlines)
        var inTable = false
        var energyColIdx = -1
        var nameColIdx = 0
        var pidColIdx = 1
        var cpuColIdx = 2

        var rows: [EnergyImpactRow] = []

        for line in lines {
            // Header detection
            if !inTable {
                if line.contains("Name") && line.contains("ID")
                    && (line.lowercased().contains("energy")
                        || line.lowercased().contains("cpu ms/s")) {

                    let cols = headerColumns(line)
                    nameColIdx = cols.firstIndex(of: "Name") ?? 0
                    pidColIdx  = cols.firstIndex(of: "ID") ?? 1
                    cpuColIdx  = cols.firstIndex(where: {
                        $0.lowercased().contains("cpu") || $0.lowercased().contains("ms/s")
                    }) ?? 2
                    energyColIdx = cols.firstIndex(where: {
                        $0.lowercased().contains("energy") || $0 == "Impact"
                    }) ?? -1
                    inTable = true
                    continue
                }
                continue
            }

            // Termination of the table
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("*") || trimmed.hasPrefix("=") {
                inTable = false
                continue
            }

            // Parse row
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                .map(String.init)
            // We need at least `cpuColIdx + 1` columns
            guard parts.count > max(nameColIdx, max(pidColIdx, cpuColIdx)) else { continue }
            let name = parts[nameColIdx]
            guard let pid = Int32(parts[pidColIdx]) else { continue }
            let cpu = Double(parts[cpuColIdx]) ?? 0
            // Energy column may be absent
            let energy: Double = {
                guard energyColIdx >= 0, energyColIdx < parts.count else { return 0 }
                return Double(parts[energyColIdx]) ?? 0
            }()
            rows.append(EnergyImpactRow(
                id: pid, name: name, energyImpact: energy, cpuMsPerSec: cpu
            ))
        }
        return rows
    }

    /// Split a header line into column names. We deliberately collapse
    /// multi-word headers ("Energy Impact" → "Energy") because the rest
    /// of the parser is index-based on whitespace-separated tokens.
    private static func headerColumns(_ line: String) -> [String] {
        line.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
    }
}

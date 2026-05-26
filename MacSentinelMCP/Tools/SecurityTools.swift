import Foundation

// MARK: - macsentinel.scan_process_trust

struct ScanProcessTrustTool: MCPToolHandler {
    let tool = MCPTool(
        name: "macsentinel.scan_process_trust",
        description: """
            Evaluate the code-signing trust level of currently running processes.
            For each process, returns a 5-level classification (apple_system /
            notarized_third_party / signed_not_notarized / adhoc_or_self_signed /
            unsigned_or_invalid), team identifier, authority chain, notarization
            status, and any high-risk entitlements held. Optionally filter to
            only show processes with issues (`only_issues`). Read-only.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "only_issues": .object([
                    "type": .string("boolean"),
                    "description": .string("If true, only return processes flagged as risky (default false)"),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Max processes to evaluate (default 50, max 500). First call may take ~2-5s; subsequent calls hit the path-keyed cache and return in <100ms."),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    func call(arguments: JSONValue?) async throws -> MCPToolResult {
        let onlyIssues = arguments?.bool("only_issues") ?? false
        var limit = 50
        if case .object(let o)? = arguments {
            if case .int(let n) = o["limit"]    { limit = n }
            if case .double(let d) = o["limit"] { limit = Int(d) }
        }
        limit = min(500, max(1, limit))

        let processes = await ProcessSnapshotService.shared.snapshotOnce()
        let candidates = Array(processes.prefix(limit))
        let trust = await ProcessTrustService.shared.evaluateAll(candidates)
        let filtered = onlyIssues ? trust.filter(\.hasIssues) : trust

        struct Envelope: Codable {
            let totalEvaluated: Int
            let totalReturned: Int
            let onlyIssues: Bool
            let processes: [ProcessTrustInfo]
        }
        return try toolJSONResult(Envelope(
            totalEvaluated: trust.count,
            totalReturned: filtered.count,
            onlyIssues: onlyIssues,
            processes: filtered
        ))
    }
}

// MARK: - macsentinel.scan_browsers

struct ScanBrowsersTool: MCPToolHandler {
    let tool = MCPTool(
        name: "macsentinel.scan_browsers",
        description: """
            Scan all installed browsers (Chrome, Brave, Edge, Arc, Vivaldi, Opera,
            Firefox, Safari) for extensions. Each extension is scored 0-100 based
            on permissions (all_urls access, webRequest, proxy, debugger, etc.)
            and provenance (Web Store vs sideloaded). Known malicious extension
            IDs are flagged as blocklist matches. Read-only.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "min_risk_level": .object([
                    "type": .string("string"),
                    "enum": .array([.string("clean"), .string("lowRisk"), .string("highRisk"), .string("blocked")]),
                    "description": .string("Only return extensions at or above this risk level (default: clean)"),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    func call(arguments: JSONValue?) async throws -> MCPToolResult {
        let minLevelKey = arguments?.string("min_risk_level") ?? "clean"
        let minLevel: ExtensionRiskLevel = {
            switch minLevelKey {
            case "lowRisk":  return .lowRisk
            case "highRisk": return .highRisk
            case "blocked":  return .blocked
            default:         return .clean
            }
        }()

        let order: [ExtensionRiskLevel] = [.clean, .lowRisk, .highRisk, .blocked]
        let minOrdinal = order.firstIndex(of: minLevel) ?? 0

        let result = await BrowserScanner.shared.scanAll()
        let filtered = result.extensions.filter {
            (order.firstIndex(of: $0.riskLevel) ?? 0) >= minOrdinal
        }

        struct Envelope: Codable {
            let summary: BrowserSummary
            let scanErrors: [String]
            let extensions: [BrowserExtension]
        }
        struct BrowserSummary: Codable {
            let total: Int
            let blocked: Int
            let highRisk: Int
            let lowRisk: Int
        }
        return try toolJSONResult(Envelope(
            summary: .init(
                total: result.totalCount,
                blocked: result.blockedCount,
                highRisk: result.highRiskCount,
                lowRisk: result.lowRiskCount
            ),
            scanErrors: result.scanErrors,
            extensions: filtered
        ))
    }
}

// MARK: - macsentinel.scan_network

struct ScanNetworkTool: MCPToolHandler {
    let tool = MCPTool(
        name: "macsentinel.scan_network",
        description: """
            Detect network-layer hijack indicators on the user's Mac:
            (1) /etc/hosts entries that override sensitive domains (Google, Apple,
            banking, etc.), (2) custom DNS servers not in the well-known list,
            (3) PAC (auto-proxy) URLs configured on any network interface,
            (4) LaunchDaemons that resemble transparent proxies. Read-only.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    )

    func call(arguments: JSONValue?) async throws -> MCPToolResult {
        let result = await NetworkScanner.shared.scan()
        return try toolJSONResult(result)
    }
}

// MARK: - macsentinel.scan_xprotect

struct ScanXProtectTool: MCPToolHandler {
    let tool = MCPTool(
        name: "macsentinel.scan_xprotect",
        description: """
            Read Apple's built-in XProtect malware-detection rule database
            (/Library/Apple/System/Library/CoreServices/XProtect.bundle) and
            return the list of currently-known malware family signatures. Useful
            for verifying whether a suspicious filename matches an Apple-tracked
            family. Note: macOS already runs XProtect automatically — this tool
            just exposes the rule list for AI correlation. Read-only.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "search": .object([
                    "type": .string("string"),
                    "description": .string("Optional substring filter applied to rule name or matcher strings"),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    func call(arguments: JSONValue?) async throws -> MCPToolResult {
        var info = await XProtectReader.shared.read()
        if let search = arguments?.string("search")?.lowercased(), !search.isEmpty {
            let filtered = info.rules.filter { rule in
                rule.id.lowercased().contains(search) ||
                (rule.family?.lowercased().contains(search) ?? false) ||
                rule.matchers.contains { $0.lowercased().contains(search) }
            }
            info = XProtectInfo(
                bundlePath: info.bundlePath, version: info.version,
                ruleCount: filtered.count, rules: filtered,
                available: info.available, note: info.note
            )
        }
        return try toolJSONResult(info)
    }
}

// MARK: - macsentinel.kill_process

struct KillProcessTool: MCPToolHandler {
    let tool = MCPTool(
        name: "macsentinel.kill_process",
        description: """
            Terminate a running process by PID. Subject to the same dry-run rules
            as trash_items: in dry-run mode (default) the call only reports
            intent. Built-in safety: refuses to kill PID 1 (launchd), PID 0
            (kernel_task), or processes whose evaluated trust level is L5 (Apple
            system). All kills are recorded in the audit log.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "pid": .object([
                    "type": .string("integer"),
                    "description": .string("Process ID to terminate"),
                ]),
                "force": .object([
                    "type": .string("boolean"),
                    "description": .string("Use SIGKILL instead of SIGTERM (default false)"),
                ]),
            ]),
            "required": .array([.string("pid")]),
            "additionalProperties": .bool(false),
        ])
    )

    func call(arguments: JSONValue?) async throws -> MCPToolResult {
        let cfg = MCPConfig.load()
        guard cfg.enabled else {
            throw MCPToolError.tool("MCP integration is disabled in MacSentinel settings.")
        }

        var pid: Int32 = 0
        if case .object(let o)? = arguments {
            if case .int(let n) = o["pid"]    { pid = Int32(n) }
            if case .double(let d) = o["pid"] { pid = Int32(d) }
        }
        guard pid > 1 else {
            throw MCPToolError.params("Refusing to kill PID \(pid) (reserved/kernel).")
        }
        let force = arguments?.bool("force") ?? false

        // Get process details for trust evaluation + audit detail
        let processes = await ProcessSnapshotService.shared.snapshotOnce()
        guard let proc = processes.first(where: { $0.id == pid }) else {
            throw MCPToolError.tool("PID \(pid) not found (process may have already exited).")
        }
        let trust = ProcessTrustService.shared.evaluate(
            pid: proc.id, path: proc.executablePath, name: proc.name)

        guard trust.trustLevel != .l5_appleSystem else {
            throw MCPToolError.protected("Refusing to kill L5 Apple system process \"\(proc.name)\" — could destabilize macOS.")
        }

        struct Envelope: Codable {
            let dryRun: Bool
            let pid: Int32
            let processName: String
            let trustLevel: String
            let signal: String
            let action: String
            let auditLogPath: String
        }

        if !cfg.allowRealDelete {
            // dry-run
            await AuditLog.shared.record(.processKill(
                pid: pid, name: proc.name, caller: "mcp-dryrun"))
            return try toolJSONResult(Envelope(
                dryRun: true, pid: pid, processName: proc.name,
                trustLevel: trust.trustLevel.jsonKey,
                signal: force ? "SIGKILL" : "SIGTERM",
                action: "would_kill",
                auditLogPath: AuditLog.shared.logURL.path
            ))
        }

        let signal = force ? SIGKILL : SIGTERM
        let killResult = kill(pid, signal)
        await AuditLog.shared.record(.processKill(
            pid: pid, name: proc.name, caller: "mcp"))

        return try toolJSONResult(Envelope(
            dryRun: false, pid: pid, processName: proc.name,
            trustLevel: trust.trustLevel.jsonKey,
            signal: force ? "SIGKILL" : "SIGTERM",
            action: killResult == 0 ? "killed" : "kill_failed_errno_\(errno)",
            auditLogPath: AuditLog.shared.logURL.path
        ))
    }
}

// MARK: - macsentinel.set_dry_run

struct SetDryRunTool: MCPToolHandler {
    let tool = MCPTool(
        name: "macsentinel.set_dry_run",
        description: """
            Toggle whether destructive tools (trash_items, kill_process) actually
            execute or simply report intent. ⚠️ Granting real-delete to an AI
            assistant means it can autonomously remove files (to Trash) — only
            do this if you trust the assistant. All operations are still gated
            by ProtectedPaths and recorded in the audit log.

            The state change is persisted to ~/Library/Application Support/MacSentinel/
            mcp-config.json and survives across MacSentinel restarts.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "enable_real_delete": .object([
                    "type": .string("boolean"),
                    "description": .string("Set to true to allow real delete; false for dry-run only."),
                ]),
            ]),
            "required": .array([.string("enable_real_delete")]),
            "additionalProperties": .bool(false),
        ])
    )

    func call(arguments: JSONValue?) async throws -> MCPToolResult {
        guard let enable = arguments?.bool("enable_real_delete") else {
            throw MCPToolError.params("Missing 'enable_real_delete' boolean")
        }
        var cfg = MCPConfig.load()
        let before = cfg.allowRealDelete
        cfg.allowRealDelete = enable
        do { try cfg.save() } catch {
            throw MCPToolError.internalErr("Failed to persist config: \(error.localizedDescription)")
        }
        await AuditLog.shared.record(.configChanged(
            key: "allowRealDelete",
            newValue: String(enable),
            caller: "mcp"
        ))

        struct Envelope: Codable {
            let allowRealDelete: Bool
            let previousValue: Bool
            let message: String
        }
        return try toolJSONResult(Envelope(
            allowRealDelete: enable,
            previousValue: before,
            message: enable
                ? "Real-delete mode enabled. Subsequent trash_items / kill_process calls will execute."
                : "Dry-run mode enabled. Destructive operations will only report intent."
        ))
    }
}

// MARK: - macsentinel.get_system_health

struct GetSystemHealthTool: MCPToolHandler {
    let tool = MCPTool(
        name: "macsentinel.get_system_health",
        description: """
            One-shot system health summary: CPU usage, memory pressure, battery,
            thermal readings (Apple Silicon HID + SMC fallback), free disk space,
            and network throughput. Use this to give the user a quick "how's my
            Mac doing right now" answer. Read-only, ~2 seconds.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    )

    func call(arguments: JSONValue?) async throws -> MCPToolResult {
        // SystemDataCollector takes 2 samples internally for accurate deltas
        let collector = SystemDataCollector.shared
        await collector.startOnce()
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        await collector.stopOnce()

        guard let snap = collector.latestSnapshot else {
            throw MCPToolError.tool("Failed to capture system snapshot")
        }

        struct Health: Codable {
            let timestamp: String
            let cpu: CPUExport
            let memory: MemExport
            let disk: DiskExport
            let battery: BattExport?
            let thermal: ThermalExport
            let network: NetExport
            let alerts: [AlertExport]
        }
        struct CPUExport: Codable {
            let usagePercent: Double
            let systemPercent: Double
            let userPercent: Double
            let alertLevel: String
        }
        struct MemExport: Codable {
            let usagePercent: Double
            let usedBytes: UInt64
            let totalBytes: UInt64
            let swapUsedBytes: UInt64
            let pressure: String
        }
        struct DiskExport: Codable {
            let usagePercent: Double
            let freeBytes: UInt64
            let totalBytes: UInt64
        }
        struct BattExport: Codable {
            let percentage: Int
            let isCharging: Bool
            let isPluggedIn: Bool
            let cycleCount: Int
            let healthPercent: Double
        }
        struct ThermalExport: Codable {
            let cpuTempC: Double
            let gpuTempC: Double
            let fanRPM: Double
            let totalPowerWatts: Double
        }
        struct NetExport: Codable {
            let uploadBytesPerSec: Double
            let downloadBytesPerSec: Double
            let activeInterface: String
        }
        struct AlertExport: Codable {
            let level: String
            let title: String
            let message: String
        }

        let formatter = ISO8601DateFormatter()
        let alertLevelString = { (l: AlertLevel) -> String in
            switch l { case .normal: return "normal"; case .warning: return "warning"; case .critical: return "critical" }
        }

        let health = Health(
            timestamp: formatter.string(from: snap.timestamp),
            cpu: .init(
                usagePercent: snap.cpu.usagePercent.rounded(toPlaces: 1),
                systemPercent: snap.cpu.systemPercent.rounded(toPlaces: 1),
                userPercent: snap.cpu.userPercent.rounded(toPlaces: 1),
                alertLevel: alertLevelString(snap.cpu.alertLevel)
            ),
            memory: .init(
                usagePercent: snap.memory.usagePercent.rounded(toPlaces: 1),
                usedBytes: snap.memory.usedBytes,
                totalBytes: snap.memory.totalBytes,
                swapUsedBytes: snap.memory.swapUsedBytes,
                pressure: {
                    switch snap.memory.pressureLevel {
                    case .normal: return "normal"
                    case .warning: return "warning"
                    case .critical: return "critical"
                    }
                }()
            ),
            disk: .init(
                usagePercent: snap.disk.usagePercent.rounded(toPlaces: 1),
                freeBytes: snap.disk.freeBytes,
                totalBytes: snap.disk.totalBytes
            ),
            battery: snap.battery.isAvailable ? .init(
                percentage: snap.battery.percentage,
                isCharging: snap.battery.isCharging,
                isPluggedIn: snap.battery.isPluggedIn,
                cycleCount: snap.battery.cycleCount,
                healthPercent: snap.battery.healthPercent.rounded(toPlaces: 3)
            ) : nil,
            thermal: .init(
                cpuTempC: snap.thermal.cpuTemperatureCelsius.rounded(toPlaces: 1),
                gpuTempC: snap.thermal.gpuTemperatureCelsius.rounded(toPlaces: 1),
                fanRPM: snap.thermal.fanSpeedRPM.rounded(),
                totalPowerWatts: snap.thermal.totalPowerWatts.rounded(toPlaces: 2)
            ),
            network: .init(
                uploadBytesPerSec: snap.network.uploadBytesPerSec.rounded(),
                downloadBytesPerSec: snap.network.downloadBytesPerSec.rounded(),
                activeInterface: snap.network.activeInterface
            ),
            alerts: collector.systemAlerts.map { .init(
                level: alertLevelString($0.level),
                title: $0.title,
                message: $0.message
            ) }
        )
        return try toolJSONResult(health)
    }
}

// MARK: - Helpers

extension Double {
    fileprivate func rounded(toPlaces places: Int) -> Double {
        let multiplier = pow(10.0, Double(places))
        return (self * multiplier).rounded() / multiplier
    }
}

import Foundation
import ServiceManagement

// MARK: - macsentinel.scan_login_items
//
// Enumerates every LaunchAgent / LaunchDaemon plist on the machine across
// the three standard locations and decorates each with a recommendation
// drawn from the StartupKnowledgeBase (40+ rules covering security
// software, backups, updaters, cloud sync, messaging, dev daemons,
// Apple system services). AI assistants use the `recommendation` +
// `reason` fields to advise users which items to disable.

struct ScanLoginItemsTool: MCPToolHandler {
    let tool = MCPTool(
        name: "macsentinel.scan_login_items",
        description: """
            Enumerate every LaunchAgent / LaunchDaemon plist installed across
            ~/Library/LaunchAgents, /Library/LaunchAgents, /Library/LaunchDaemons.
            For each item the response includes a heuristic recommendation
            ("shouldEnable" / "shouldDisable" / "neutral") and a 中文 reason
            drawn from a built-in 40+ rule knowledge base. AI assistants
            should use these to help the user decide what to keep enabled.

            Use `suggest_disable_only=true` to get just the items the
            knowledge base recommends turning off (and which are currently
            enabled) — the highest-signal answer for "what should I turn off?"

            Read-only. Toggling items requires admin password and is exposed
            only in the GUI.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "only_enabled": .object([
                    "type": .string("boolean"),
                    "description": .string("If true, only return items that are currently enabled (default false)"),
                ]),
                "suggest_disable_only": .object([
                    "type": .string("boolean"),
                    "description": .string("If true, only return items whose recommendation is 'shouldDisable' AND are currently enabled — i.e. the highest-value cleanup candidates"),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    struct LoginItem: Codable {
        let label: String
        let name: String
        let path: String
        let program: String
        let enabled: Bool
        let scope: String           // "user" | "system_agent" | "system_daemon"
        let recommendation: String  // "shouldEnable" | "shouldDisable" | "neutral"
        let reason: String          // 中文 rationale
    }

    func call(arguments: JSONValue?) async throws -> MCPToolResult {
        let onlyEnabled        = arguments?.bool("only_enabled") ?? false
        let suggestDisableOnly = arguments?.bool("suggest_disable_only") ?? false

        var raw = StartupItemService.collectItemsStatic()
        if onlyEnabled { raw = raw.filter(\.isEnabled) }
        if suggestDisableOnly {
            raw = raw.filter { $0.isEnabled && $0.recommendation == .shouldDisable }
        }

        let items: [LoginItem] = raw.map { it in
            LoginItem(
                label: it.label,
                name: it.name,
                path: it.path,
                program: it.program,
                enabled: it.isEnabled,
                scope: scopeLabel(for: it),
                recommendation: machineRec(it.recommendation),
                reason: it.descriptionText
            )
        }

        struct Envelope: Codable {
            let total: Int
            let total_enabled: Int
            let total_suggesting_disable: Int
            let items: [LoginItem]
        }
        let env = Envelope(
            total: items.count,
            total_enabled: items.filter(\.enabled).count,
            total_suggesting_disable: items.filter {
                $0.recommendation == "shouldDisable" && $0.enabled
            }.count,
            items: items
        )
        return try toolJSONResult(env)
    }

    private func scopeLabel(for item: StartupItem) -> String {
        if item.path.contains("/Library/LaunchDaemons") { return "system_daemon" }
        if item.path.contains("/Library/LaunchAgents")  { return "system_agent" }
        return "user"
    }

    /// Map the localised raw enum value to a stable machine-readable key
    /// for the MCP JSON contract.
    private func machineRec(_ r: StartupRecommendation) -> String {
        switch r {
        case .shouldEnable:  return "shouldEnable"
        case .shouldDisable: return "shouldDisable"
        case .neutral:       return "neutral"
        }
    }
}

// MARK: - macsentinel.analyze_hosts_diff
//
// Reads /etc/hosts and diffs it against a known-good baseline (vendor /
// Apple defaults). Flags unusual entries: redirects of Apple/Google domains,
// custom blocklists pulled from suspicious sources, etc.

struct AnalyzeHostsDiffTool: MCPToolHandler {
    let tool = MCPTool(
        name: "macsentinel.analyze_hosts_diff",
        description: """
            Compare /etc/hosts against the macOS default and surface custom
            entries. Highlights redirects of high-value domains (apple.com,
            icloud.com, google.com, github.com…) which are a common adware /
            credential-phishing pattern. Read-only.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    )

    struct HostEntry: Codable {
        let ip: String
        let hostname: String
        let isSuspicious: Bool
        let reason: String?
    }

    /// Domains we never expect to see redirected in a clean hosts file.
    private static let sensitiveDomains: [String] = [
        "apple.com", "icloud.com", "itunes.com", "mzstatic.com",
        "google.com", "googleapis.com", "gstatic.com", "youtube.com",
        "github.com", "githubusercontent.com",
        "microsoft.com", "live.com", "office.com",
        "anthropic.com", "claude.ai",
        "facebook.com", "instagram.com",
        "icloud-content.com", "akamaiedge.net",
    ]

    func call(arguments: JSONValue?) async throws -> MCPToolResult {
        let url = URL(fileURLWithPath: "/etc/hosts")
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) }
        catch {
            return toolTextResult("Cannot read /etc/hosts: \(error.localizedDescription)",
                                  isError: true)
        }

        // macOS default lines we treat as baseline noise
        let defaults: Set<String> = [
            "127.0.0.1 localhost",
            "255.255.255.255 broadcasthost",
            "::1 localhost",
        ]

        var entries: [HostEntry] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let collapsed = line
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            if defaults.contains(collapsed) { continue }
            let tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard tokens.count >= 2 else { continue }
            let ip = tokens[0]
            for host in tokens.dropFirst() {
                let lower = host.lowercased()
                var suspicious = false
                var reason: String?
                for s in Self.sensitiveDomains {
                    if lower == s || lower.hasSuffix(".\(s)") {
                        suspicious = true
                        reason = "Redirects sensitive domain '\(s)' to \(ip)"
                        break
                    }
                }
                // Loopback rerouting is usually benign for ad-blocker lists,
                // but redirecting a sensitive domain to a public IP is alarming.
                if suspicious, ip != "0.0.0.0", ip != "127.0.0.1", ip != "::" {
                    reason = (reason ?? "") + " (non-blackhole target)"
                }
                entries.append(HostEntry(
                    ip: ip, hostname: host,
                    isSuspicious: suspicious, reason: reason
                ))
            }
        }

        struct Envelope: Codable {
            let totalCustomEntries: Int
            let suspiciousCount: Int
            let entries: [HostEntry]
        }
        return try toolJSONResult(Envelope(
            totalCustomEntries: entries.count,
            suspiciousCount: entries.filter(\.isSuspicious).count,
            entries: entries
        ))
    }
}

// MARK: - macsentinel.kext_history
//
// Lists currently loaded kexts plus residual kext bundles found in
// /Library/Extensions (third-party) and /Library/StagedExtensions (kextcache
// staging on Apple Silicon). Useful for spotting legacy kexts that survive
// `kextcache` rebuilds.

struct KextHistoryTool: MCPToolHandler {
    let tool = MCPTool(
        name: "macsentinel.kext_history",
        description: """
            List currently loaded kernel extensions (via kmutil) and any
            third-party kext bundles still present in /Library/Extensions or
            /Library/StagedExtensions. Each entry includes bundle ID, version,
            on-disk path and whether it is still loaded. Read-only.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    )

    struct KextEntry: Codable {
        let bundleID: String
        let version: String?
        let path: String?
        let isLoaded: Bool
        let isAppleSigned: Bool
    }

    func call(arguments: JSONValue?) async throws -> MCPToolResult {
        var loadedIDs: Set<String> = []

        // 1. kmutil showloaded — get loaded bundle IDs
        if let out = runShell("/usr/bin/kmutil", ["showloaded", "--list-only"]) {
            for line in out.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // kmutil prints lines like:
                //   0xfffffff007d99000  17456k 0    com.apple.driver.AppleACPIPlatform   8.1
                // Bundle ID is column 4-ish; just scan all whitespace-separated tokens for a com.* pattern.
                for tok in trimmed.split(whereSeparator: \.isWhitespace) {
                    let s = String(tok)
                    if s.contains(".") && (s.hasPrefix("com.") || s.hasPrefix("org.") || s.hasPrefix("net.")) {
                        loadedIDs.insert(s)
                        break
                    }
                }
            }
        }

        var entries: [KextEntry] = []
        let dirs = ["/Library/Extensions", "/Library/StagedExtensions"]
        for dir in dirs {
            guard let kexts = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for name in kexts where name.hasSuffix(".kext") {
                let kextPath = "\(dir)/\(name)"
                let infoPath = "\(kextPath)/Contents/Info.plist"
                var bundleID = name
                var version: String?
                if let data = try? Data(contentsOf: URL(fileURLWithPath: infoPath)),
                   let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    bundleID = (plist["CFBundleIdentifier"] as? String) ?? name
                    version  = plist["CFBundleShortVersionString"] as? String
                                ?? plist["CFBundleVersion"] as? String
                }
                let isLoaded = loadedIDs.contains(bundleID)
                let appleSigned = bundleID.hasPrefix("com.apple.")
                entries.append(KextEntry(
                    bundleID: bundleID, version: version,
                    path: kextPath, isLoaded: isLoaded,
                    isAppleSigned: appleSigned
                ))
            }
        }

        // Also include any loaded kext we didn't find on disk (in cache only)
        for id in loadedIDs where !entries.contains(where: { $0.bundleID == id }) {
            entries.append(KextEntry(
                bundleID: id, version: nil, path: nil,
                isLoaded: true,
                isAppleSigned: id.hasPrefix("com.apple.")
            ))
        }

        struct Envelope: Codable {
            let totalLoaded: Int
            let totalOnDisk: Int
            let thirdPartyOnDisk: Int
            let entries: [KextEntry]
        }
        return try toolJSONResult(Envelope(
            totalLoaded: loadedIDs.count,
            totalOnDisk: entries.filter { $0.path != nil }.count,
            thirdPartyOnDisk: entries.filter { $0.path != nil && !$0.isAppleSigned }.count,
            entries: entries
        ))
    }
}

// MARK: - Shared helper

private func runShell(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> String? {
    let process = Process()
    process.launchPath = path
    process.arguments = args
    let out = Pipe(); let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    do { try process.run() } catch { return nil }
    process.waitUntilExit()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
}

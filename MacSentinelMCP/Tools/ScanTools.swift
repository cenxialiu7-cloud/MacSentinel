import Foundation

// MARK: - macsentinel.scan_caches

struct ScanCachesTool: MCPToolHandler {
    let tool = MCPTool(
        name: "macsentinel.scan_caches",
        description: """
            Scan the user's Mac for safely-clearable cache files across 6 categories:
            browser caches (Chrome, Brave, Safari, Firefox, Edge, Arc), developer tool
            caches (Xcode DerivedData, iOS DeviceSupport, npm, pip, Homebrew, Playwright,
            CocoaPods, Swift PM), system caches, media assets, app logs, and other junk.
            Returns a structured JSON report with paths, sizes, and safety classifications.
            Read-only — does not delete anything.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    )

    func call(arguments: JSONValue?) async throws -> MCPToolResult {
        let result = await CacheScanner.shared.scan()
        let report = AIScanReporter.shared.report(from: result)
        return try toolJSONResult(report)
    }
}

// MARK: - macsentinel.scan_apps

struct ScanAppsTool: MCPToolHandler {
    let tool = MCPTool(
        name: "macsentinel.scan_apps",
        description: """
            Scan /Applications for installed apps. For each app, returns: name, bundle ID,
            version, architecture (arm64 / x86_64 / universal), bundle size, total size
            (bundle + residual files), and (optionally) residual paths.

            ⚠️ Tip: with `include_residuals=true` the response can be very large
            (~300 KB for a typical user). Use `summary_only=true` for a much smaller
            response when you only need the app list, or `filter_arch="x86_64"` to
            narrow to Intel-only apps. `limit` caps the number of apps returned
            (sorted by total size descending).
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "include_residuals": .object([
                    "type": .string("boolean"),
                    "description": .string("Include detailed residual file list (default true)"),
                ]),
                "summary_only": .object([
                    "type": .string("boolean"),
                    "description": .string("Return only name+bundle+version+arch+size (default false)"),
                ]),
                "filter_arch": .object([
                    "type": .string("string"),
                    "enum": .array([.string("arm64"), .string("x86_64"), .string("Universal"), .string("Unknown")]),
                    "description": .string("Only return apps matching this architecture"),
                ]),
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Max apps to return (default 50, max 200)"),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    func call(arguments: JSONValue?) async throws -> MCPToolResult {
        let includeResiduals = arguments?.bool("include_residuals") ?? true
        let summaryOnly = arguments?.bool("summary_only") ?? false
        let archFilter = arguments?.string("filter_arch")
        var limit = 50
        if case .object(let o)? = arguments {
            if case .int(let n) = o["limit"]    { limit = n }
            if case .double(let d) = o["limit"] { limit = Int(d) }
        }
        limit = min(200, max(1, limit))

        var apps = await AppResidualScanner.shared.scanInstalledApps()

        // Filter by architecture if requested
        if let arch = archFilter {
            apps = apps.filter { $0.architecture.rawValue == arch }
        }
        // Sort by total size desc, then truncate
        apps = apps.sorted { $0.totalSizeBytes > $1.totalSizeBytes }.prefix(limit).map { $0 }

        // Format compactly for AI consumption
        struct AppExport: Codable {
            let name: String
            let bundleID: String
            let bundlePath: String
            let version: String
            let architecture: String
            let bundleSizeBytes: UInt64
            let totalSizeBytes: UInt64
            let needsRosetta: Bool
            let residuals: [ResidualExport]
            let launchAgents: [LaunchAgentExport]
        }
        struct ResidualExport: Codable {
            let path: String
            let category: String
            let sizeBytes: UInt64
            let safetyLevel: String
        }
        struct LaunchAgentExport: Codable {
            let label: String
            let plistPath: String
            let isLoaded: Bool
            let isOrphaned: Bool
        }

        let report = apps.map { app -> AppExport in
            // Slim down based on options
            let residuals: [ResidualExport] = (summaryOnly || !includeResiduals)
                ? []
                : app.residuals.map { r in
                    ResidualExport(
                        path: r.path,
                        category: r.category.rawValue,
                        sizeBytes: r.sizeBytes,
                        safetyLevel: r.safetyLevel.jsonKey
                    )
                }
            let launchAgents: [LaunchAgentExport] = summaryOnly
                ? []
                : app.launchAgents.map { a in
                    LaunchAgentExport(
                        label: a.label,
                        plistPath: a.plistPath,
                        isLoaded: a.isLoaded,
                        isOrphaned: a.isOrphaned
                    )
                }
            return AppExport(
                name: app.name,
                bundleID: app.bundleID,
                bundlePath: app.bundlePath,
                version: app.version,
                architecture: app.architecture.rawValue,
                bundleSizeBytes: app.bundleSizeBytes,
                totalSizeBytes: app.totalSizeBytes,
                needsRosetta: app.needsRosetta,
                residuals: residuals,
                launchAgents: launchAgents
            )
        }

        struct Envelope: Codable {
            let totalCount: Int
            let returnedCount: Int
            let summaryOnly: Bool
            let archFilter: String?
            let apps: [AppExport]
        }
        return try toolJSONResult(Envelope(
            totalCount: apps.count,
            returnedCount: report.count,
            summaryOnly: summaryOnly,
            archFilter: archFilter,
            apps: report
        ))
    }
}

// MARK: - macsentinel.scan_migration

struct ScanMigrationTool: MCPToolHandler {
    let tool = MCPTool(
        name: "macsentinel.scan_migration",
        description: """
            Scan for orphaned data and architecture mismatches typical of Mac upgrades
            or Intel→Apple Silicon migration: (1) Intel-only apps that need Rosetta 2,
            (2) Launch agents pointing to missing executables, (3) Container folders
            whose owning app has been deleted, (4) Legacy third-party kexts no longer
            supported on Apple Silicon. Returns counts, sizes, and full paths. Read-only.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    )

    func call(arguments: JSONValue?) async throws -> MCPToolResult {
        let result = await MigrationScanner.shared.fullScan()

        struct MigrationExport: Codable {
            struct RosettaAppExport: Codable {
                let name: String
                let bundleID: String
                let bundlePath: String
                let version: String
                let sizeBytes: UInt64
            }
            struct OrphanedAgentExport: Codable {
                let label: String
                let plistPath: String
                let missingExecutable: String
                let isUserAgent: Bool
            }
            struct OrphanedContainerExport: Codable {
                let bundleID: String
                let containerPath: String
                let sizeBytes: UInt64
                let isGroupContainer: Bool
            }
            struct LegacyKextExport: Codable {
                let name: String
                let bundleID: String
                let path: String
                let isLoaded: Bool
                let isAppleSigned: Bool
            }
            let rosettaApps: [RosettaAppExport]
            let orphanedLaunchAgents: [OrphanedAgentExport]
            let orphanedContainers: [OrphanedContainerExport]
            let legacyKexts: [LegacyKextExport]
            let totalOrphanBytes: UInt64
        }

        let export = MigrationExport(
            rosettaApps: result.rosettaApps.map {
                .init(name: $0.name, bundleID: $0.bundleID, bundlePath: $0.bundlePath,
                      version: $0.version, sizeBytes: $0.bundleSizeBytes)
            },
            orphanedLaunchAgents: result.orphanedLaunchAgents.map {
                .init(label: $0.label, plistPath: $0.plistPath,
                      missingExecutable: $0.missingExecutable, isUserAgent: $0.isUserAgent)
            },
            orphanedContainers: result.orphanedContainers.map {
                .init(bundleID: $0.bundleID, containerPath: $0.containerPath,
                      sizeBytes: $0.sizeBytes, isGroupContainer: $0.isGroupContainer)
            },
            legacyKexts: result.legacyKexts.map {
                .init(name: $0.name, bundleID: $0.bundleID, path: $0.path,
                      isLoaded: $0.isLoaded, isAppleSigned: $0.isAppleSigned)
            },
            totalOrphanBytes: result.totalOrphanBytes
        )
        return try toolJSONResult(export)
    }
}

// MARK: - macsentinel.list_capabilities

struct ListCapabilitiesTool: MCPToolHandler {
    let tool = MCPTool(
        name: "macsentinel.list_capabilities",
        description: """
            Return a structured overview of all MacSentinel MCP tools, the current
            dry-run / real-delete mode, and the list of immutable protected paths
            (paths that MacSentinel will refuse to touch under any circumstances).
            Call this first to understand what's safe to do.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
            "additionalProperties": .bool(false),
        ])
    )

    func call(arguments: JSONValue?) async throws -> MCPToolResult {
        let cfg = MCPConfig.load()

        struct Capabilities: Codable {
            let serverVersion: String
            let mcpEnabled: Bool
            let allowRealDelete: Bool
            let allowedTools: [String]
            let immutableProtectedPaths: [String]
            let notes: String
        }
        let caps = Capabilities(
            serverVersion: "1.0.0",
            mcpEnabled: cfg.enabled,
            allowRealDelete: cfg.allowRealDelete,
            allowedTools: [
                // Read-only scan tools
                "macsentinel.list_capabilities",
                "macsentinel.scan_caches",
                "macsentinel.scan_apps",
                "macsentinel.scan_migration",
                "macsentinel.list_processes",
                "macsentinel.scan_process_trust",
                "macsentinel.scan_browsers",
                "macsentinel.scan_network",
                "macsentinel.scan_xprotect",
                "macsentinel.get_system_health",
                "macsentinel.read_audit_log",
                // Write tools (gated by allowRealDelete)
                "macsentinel.trash_items",
                "macsentinel.kill_process",
                "macsentinel.set_dry_run",
            ],
            immutableProtectedPaths: Array(ProtectedPaths.protected).sorted(),
            notes: cfg.allowRealDelete
                ? "Real-delete mode is ENABLED. trash_items will move files to the Trash (recoverable)."
                : "DRY-RUN mode. trash_items will only report what would be removed; nothing is actually deleted. User must enable real-delete in MacSentinel settings."
        )
        return try toolJSONResult(caps)
    }
}

import Foundation

// MARK: - macsentinel.trash_items
//
// The ONLY write-mode tool. Heavily gated:
//   1. If MCPConfig.allowRealDelete = false (the default), this tool runs in
//      dry-run mode — it returns what *would* be moved but does NOT actually
//      delete anything.
//   2. ProtectedPaths.isProtected() is consulted for every path. Protected
//      paths are unconditionally rejected — even if the user enabled real
//      delete mode and the AI explicitly asked.
//   3. Every operation (dry-run or real) is written to the audit log with
//      caller="mcp" so the user can trace what AI assistants have done.
//   4. Items are moved to the Trash via FileManager.trashItem — they can
//      always be recovered manually.

struct TrashItemsTool: MCPToolHandler {
    let tool = MCPTool(
        name: "macsentinel.trash_items",
        description: """
            Move a list of files or directories to the user's Trash. SAFETY:
            (1) Defaults to DRY-RUN — does not actually delete unless the user
            has explicitly enabled real-delete mode in MacSentinel Settings.
            (2) Paths in MacSentinel's protected-paths list (system roots,
            Documents, Desktop, Downloads, Keychain, Mail, Safari, Messages,
            iCloud, etc.) are unconditionally rejected.
            (3) All deletions go to the Trash and are recoverable.
            (4) Every call is recorded in the audit log.

            Returns a per-path result describing what happened (deleted, would-be-deleted,
            protected, or error). Always show this report to the user before considering
            the operation complete.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "paths": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("string")]),
                    "description": .string("Absolute filesystem paths to move to Trash."),
                ]),
                "force_dry_run": .object([
                    "type": .string("boolean"),
                    "description": .string("If true, simulate even when user has enabled real-delete (default: false)"),
                ]),
            ]),
            "required": .array([.string("paths")]),
            "additionalProperties": .bool(false),
        ])
    )

    func call(arguments: JSONValue?) async throws -> MCPToolResult {
        let cfg = MCPConfig.load()
        guard cfg.enabled else {
            throw MCPToolError.tool("MCP integration is disabled in MacSentinel settings.")
        }

        guard let pathValues = arguments?.array("paths") else {
            throw MCPToolError.params("Missing 'paths' array")
        }
        let paths: [String] = pathValues.compactMap {
            if case .string(let s) = $0 { return s } else { return nil }
        }
        guard !paths.isEmpty else {
            throw MCPToolError.params("'paths' must be a non-empty array of strings")
        }

        let forceDryRun = arguments?.bool("force_dry_run") ?? false
        let effectiveDryRun = forceDryRun || !cfg.allowRealDelete

        // Result structure
        struct ItemResult: Codable {
            let path: String
            let action: String      // "would_delete" | "deleted" | "protected" | "error" | "missing"
            let sizeBytes: UInt64?
            let safetyLevel: String?
            let reason: String?
            let failureCategory: String?   // tccBlocked / rootRequired / maclACL / protectedByPolicy / unknown
            let suggestion: String?         // human-readable remediation hint
        }
        struct Envelope: Codable {
            let dryRun: Bool
            let totalItems: Int
            let willDeleteCount: Int
            let protectedCount: Int
            let errorCount: Int
            let totalBytes: UInt64
            let results: [ItemResult]
            let auditLogPath: String
        }

        var urls: [URL] = []
        var results: [ItemResult] = []
        var willDeleteCount = 0
        var protectedCount = 0
        var errorCount = 0
        var totalBytes: UInt64 = 0

        // 1. Validate every path FIRST, before touching anything
        for p in paths {
            let url = URL(fileURLWithPath: p)

            // Existence check
            guard FileManager.default.fileExists(atPath: url.path) else {
                results.append(.init(path: p, action: "missing",
                                      sizeBytes: nil, safetyLevel: nil,
                                      reason: "File does not exist",
                                      failureCategory: nil, suggestion: nil))
                errorCount += 1
                continue
            }

            // Protection check
            if ProtectedPaths.isProtected(url) {
                results.append(.init(path: p, action: "protected",
                                      sizeBytes: nil,
                                      safetyLevel: nil,
                                      reason: "Path is in MacSentinel's immutable protected-paths list",
                                      failureCategory: DeletionFailureReason.protectedByPolicy.rawValue,
                                      suggestion: "此路徑屬於敏感資料（如 Keychain / Mail / Safari history），MacSentinel 不會碰它。如確認要刪除，請手動透過 Finder 處理。"))
                protectedCount += 1
                continue
            }

            // Compute size for reporting
            let size = sizeForReporting(url: url)
            totalBytes += size
            urls.append(url)
            willDeleteCount += 1

            results.append(.init(
                path: p,
                action: effectiveDryRun ? "would_delete" : "pending_delete",
                sizeBytes: size,
                safetyLevel: SafetyClassifier.classify(path: p).jsonKey,
                reason: nil,
                failureCategory: nil, suggestion: nil
            ))
        }

        // 2. If real delete is allowed AND there are safe URLs, do it
        if !effectiveDryRun && !urls.isEmpty {
            let deleteResult = await SafeDeleteService.shared.remove(items: urls)

            // Update result actions based on what actually succeeded
            let deletedPathSet = Set(deleteResult.deleted.map { $0.0.path })
            let failedPathSet  = Set(deleteResult.failed.map { $0.0.path })

            results = results.map { r -> ItemResult in
                if r.action == "pending_delete" {
                    if deletedPathSet.contains(r.path) {
                        return .init(path: r.path, action: "deleted",
                                     sizeBytes: r.sizeBytes,
                                     safetyLevel: r.safetyLevel,
                                     reason: nil,
                                     failureCategory: nil, suggestion: nil)
                    } else if failedPathSet.contains(r.path) {
                        errorCount += 1
                        let failure = deleteResult.failed.first { $0.0.path == r.path }
                        let cls = DeletionFailureClassifier.classify(
                            path: r.path,
                            error: failure?.1
                        )
                        return .init(path: r.path, action: "error",
                                     sizeBytes: r.sizeBytes,
                                     safetyLevel: r.safetyLevel,
                                     reason: failure?.1.localizedDescription ?? "Unknown error",
                                     failureCategory: cls.reason.rawValue,
                                     suggestion: cls.suggestion)
                    } else {
                        errorCount += 1
                        return .init(path: r.path, action: "error",
                                     sizeBytes: r.sizeBytes,
                                     safetyLevel: r.safetyLevel,
                                     reason: "Item not found in deletion result (possibly skipped post-hoc)",
                                     failureCategory: DeletionFailureReason.unknown.rawValue,
                                     suggestion: "請重新掃描確認檔案狀態")
                    }
                }
                return r
            }

            // Audit log — bulk entry with caller="mcp"
            await AuditLog.shared.record(.bulkDeletion(
                paths: urls.map(\.path),
                totalBytes: deleteResult.totalDeletedBytes,
                caller: "mcp"
            ))
        } else if !urls.isEmpty {
            // Dry-run — log proposed action so user can audit AI requests
            await AuditLog.shared.record(.bulkDeletion(
                paths: urls.map(\.path),
                totalBytes: totalBytes,
                caller: "mcp-dryrun"
            ))
        }

        let envelope = Envelope(
            dryRun: effectiveDryRun,
            totalItems: paths.count,
            willDeleteCount: willDeleteCount,
            protectedCount: protectedCount,
            errorCount: errorCount,
            totalBytes: totalBytes,
            results: results,
            auditLogPath: AuditLog.shared.logURL.path  // nonisolated access
        )
        return try toolJSONResult(envelope)
    }

    private func sizeForReporting(url: URL) -> UInt64 {
        // Lightweight: only file size if it's a single file; for directories
        // we'd need to enumerate, which is expensive — skip and return 0.
        let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if rv?.isDirectory == true { return 0 }
        return UInt64(rv?.fileSize ?? 0)
    }
}

// MARK: - macsentinel.read_audit_log

struct ReadAuditLogTool: MCPToolHandler {
    let tool = MCPTool(
        name: "macsentinel.read_audit_log",
        description: """
            Read the most recent operations from MacSentinel's audit log (deletions,
            scans, launch agent changes). Useful for AI assistants to verify what has
            already been done, or to summarize recent activity for the user.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Max number of entries to return (default 50, max 500)"),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    func call(arguments: JSONValue?) async throws -> MCPToolResult {
        var limit = 50
        if case .object(let o)? = arguments {
            if case .int(let n) = o["limit"] { limit = n }
            if case .double(let d) = o["limit"] { limit = Int(d) }
        }
        limit = min(500, max(1, limit))

        // Read raw file lines (latest entries are at the end)
        guard let data = try? Data(contentsOf: AuditLog.shared.logURL),
              let text = String(data: data, encoding: .utf8)
        else {
            return try toolJSONResult(["entries": [String]()])
        }

        let lines = text.split(separator: "\n").suffix(limit).map(String.init)

        struct Envelope: Codable {
            let logPath: String
            let returnedCount: Int
            let entries: [String]
        }
        return try toolJSONResult(Envelope(
            logPath: AuditLog.shared.logURL.path,
            returnedCount: lines.count,
            entries: lines
        ))
    }
}

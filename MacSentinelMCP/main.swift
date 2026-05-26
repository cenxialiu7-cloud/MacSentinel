import Foundation

// MARK: - macsentinel-mcp entry point
//
// Spawned by an MCP client (Claude Code, Cursor, Cowork, etc.). Reads
// JSON-RPC 2.0 messages on stdin, writes responses on stdout, logs to stderr.
//
// Config:
//   ~/Library/Application Support/MacSentinel/mcp-config.json
//
// Tools exposed (see ./Tools/):
//   • macsentinel.list_capabilities    — server info + dry-run state + protected paths
//   • macsentinel.scan_caches          — 6-category cache scan
//   • macsentinel.scan_apps            — installed apps + residuals
//   • macsentinel.scan_migration       — Rosetta apps, orphans, kexts
//   • macsentinel.list_processes       — top N processes by CPU/memory
//   • macsentinel.read_audit_log       — recent operation history
//   • macsentinel.trash_items          — DANGEROUS: move paths to Trash (gated)

let server = MCPServer()
// Read-only scan tools
server.register(ListCapabilitiesTool())
server.register(ScanCachesTool())
server.register(ScanAppsTool())
server.register(ScanMigrationTool())
server.register(ListProcessesTool())
server.register(ScanProcessTrustTool())
server.register(ScanBrowsersTool())
server.register(ScanNetworkTool())
server.register(ScanXProtectTool())
server.register(GetSystemHealthTool())
server.register(ScanLoginItemsTool())
server.register(AnalyzeHostsDiffTool())
server.register(KextHistoryTool())
server.register(ReadAuditLogTool())
// Write tools (gated by allowRealDelete)
server.register(TrashItemsTool())
server.register(KillProcessTool())
server.register(SetDryRunTool())

// Run the server on a background Task while the main thread keeps spinning
// the RunLoop. This is important: a blocked main thread would prevent any
// MainActor-isolated work (like ProcessSnapshotService.refresh) from making
// progress, causing tool calls to hang.
Task {
    await server.run()
    exit(0)
}
RunLoop.main.run()

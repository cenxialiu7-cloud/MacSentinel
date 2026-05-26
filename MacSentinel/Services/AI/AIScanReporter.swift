import Foundation

// MARK: - AI Scan Report
//
// Exports scan results in a structured format that an external AI assistant
// (Claude, ChatGPT) or a local MCP server can consume for "second-opinion"
// verification before the user deletes anything.
//
// Privacy: all paths are user-local; we never transmit file contents,
// only metadata (path, size, safety classification).

struct AIScanReport: Codable {
    var schemaVersion: Int = 1
    let exportedAt: Date
    let machineModel: String
    let osVersion: String
    let reportType: ReportType
    let items: [ReportItem]

    enum ReportType: String, Codable {
        case cacheClean
        case appUninstall
        case migration
    }

    struct ReportItem: Codable {
        let path: String
        let displayName: String
        let category: String
        let sizeBytes: UInt64
        let safetyLevel: String  // "safe" | "recommended" | "caution" | "risky"
        let isCurrentlySelected: Bool
        let userVisibleContext: String?  // human-readable hint, e.g. "Chrome browser cache"
    }
}

// MARK: - Reporter

final class AIScanReporter {

    static let shared = AIScanReporter()
    private init() {}

    private var aiEnabled: Bool {
        UserDefaults.standard.bool(forKey: "aiVerificationEnabled")
    }
    private var aiAutoExport: Bool {
        UserDefaults.standard.bool(forKey: "aiAutoExport")
    }

    // MARK: - Public API

    /// Produce a report for a cache scan result.
    func report(from cacheScan: CacheScanResult) -> AIScanReport {
        var items: [AIScanReport.ReportItem] = []
        for category in cacheScan.categories {
            for item in category.items {
                items.append(.init(
                    path: item.path,
                    displayName: item.name,
                    category: category.type.rawValue,
                    sizeBytes: item.sizeBytes,
                    safetyLevel: safetyKey(item.safetyLevel),
                    isCurrentlySelected: item.isSelected && category.isSelected,
                    userVisibleContext: contextHint(for: item.path)
                ))
            }
        }
        return makeReport(type: .cacheClean, items: items)
    }

    /// Produce a report for an app-uninstall flow.
    func report(from app: AppBundleInfo) -> AIScanReport {
        var items: [AIScanReport.ReportItem] = [
            .init(
                path: app.bundlePath,
                displayName: app.name,
                category: "Application Bundle",
                sizeBytes: app.bundleSizeBytes,
                safetyLevel: "caution",
                isCurrentlySelected: true,
                userVisibleContext: "Application \(app.name) (\(app.bundleID), \(app.architecture.label))"
            )
        ]
        for r in app.residuals {
            items.append(.init(
                path: r.path,
                displayName: r.category.rawValue,
                category: r.category.rawValue,
                sizeBytes: r.sizeBytes,
                safetyLevel: safetyKey(r.safetyLevel),
                isCurrentlySelected: r.isSelected,
                userVisibleContext: nil
            ))
        }
        return makeReport(type: .appUninstall, items: items)
    }

    /// Write a report JSON to a temporary file and return the URL.
    /// Caller can then attach it to a Mail draft, share to Claude.app, etc.
    func exportToTempFile(_ report: AIScanReport) throws -> URL {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "MacSentinel-\(report.reportType.rawValue)-\(Int(Date().timeIntervalSince1970)).json"
        let url = tempDir.appendingPathComponent(fileName)
        try data.write(to: url)
        return url
    }

    /// Build the prompt that the user (or an MCP integration) sends along with
    /// the JSON report. Phrasing is critical for getting useful verification.
    func recommendedPrompt(for report: AIScanReport) -> String {
        let role = """
        You are a macOS cleanup safety reviewer. The user is about to delete the \
        items in the attached JSON. For each item, respond with:
          • verdict: "safe_to_delete" / "review_needed" / "do_not_delete"
          • reason: one sentence
        Only flag review_needed or do_not_delete when there is a concrete reason \
        (e.g., the path is referenced by a still-installed app, deleting it \
        would lose unrecoverable user data, the file is a system trust store).
        Caches, derived data, logs, browser temp files are ALWAYS safe_to_delete.
        Reply as JSON: { "verdicts": [{ "path": "...", "verdict": "...", "reason": "..." }] }
        """
        return role
    }

    // MARK: - Helpers

    private func makeReport(type: AIScanReport.ReportType,
                            items: [AIScanReport.ReportItem]) -> AIScanReport {
        AIScanReport(
            exportedAt: Date(),
            machineModel: sysctlString("hw.model"),
            osVersion: Foundation.ProcessInfo.processInfo.operatingSystemVersionString,
            reportType: type,
            items: items
        )
    }

    private func safetyKey(_ level: SafetyLevel) -> String {
        switch level {
        case .safe:        return "safe"
        case .recommended: return "recommended"
        case .caution:     return "caution"
        case .risky:       return "risky"
        }
    }

    /// Add a short human description for known well-known paths.
    /// This helps the AI ground its verdict in actual semantics, not blind path matching.
    private func contextHint(for path: String) -> String? {
        let p = path.lowercased()
        if p.contains("library/caches/google")       { return "Google Chrome browser cache" }
        if p.contains("library/caches/bravesoftware")  || p.contains("com.brave.browser") { return "Brave browser cache" }
        if p.contains("xcode/deriveddata")            { return "Xcode build derived data (regenerated on next build)" }
        if p.contains("ios devicesupport")            { return "iOS device debug symbols (auto-redownloaded by Xcode)" }
        if p.contains("library/caches/homebrew")      { return "Homebrew package manager download cache" }
        if p.contains(".npm/_cacache") || p.contains(".cache/pip") { return "Language package manager cache (auto-regenerated)" }
        if p.contains("aerials/videos")               { return "macOS dynamic wallpaper video assets" }
        if p.contains("ms-playwright")                { return "Playwright browser automation cache" }
        if p.contains("library/launchagents/")        { return "User Launch Agent (auto-runs on login)" }
        if p.contains("library/containers/")          { return "Sandboxed app's data container" }
        if p.contains("library/preferences/")         { return "App preference plist" }
        return nil
    }

    private func sysctlString(_ key: String) -> String {
        var size: Int = 0
        sysctlbyname(key, nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(key, &buf, &size, nil, 0)
        return String(cString: buf)
    }
}

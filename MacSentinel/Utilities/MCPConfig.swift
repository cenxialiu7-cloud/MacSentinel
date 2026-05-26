import Foundation

/// Shared on-disk config read by both the GUI app (writer) and the
/// MacSentinelMCP CLI (reader). Lives at
///   ~/Library/Application Support/MacSentinel/mcp-config.json
///
/// We use a JSON file rather than UserDefaults so the CLI doesn't depend on
/// the main app's bundle id lookup or on opening a preferences plist.
struct MCPConfig: Codable {
    /// Master switch. When false, the MCP CLI will refuse all tool calls.
    var enabled: Bool = true

    /// When false (default), the trash_items tool only reports what *would*
    /// be deleted — it does not actually move anything to the Trash.
    /// The user must explicitly opt in to autonomous AI deletion.
    var allowRealDelete: Bool = false

    /// Optional per-call confirmation flow — for v1 we just gate via the
    /// allowRealDelete bool; this field is reserved for future use.
    var requireConfirmationPerCall: Bool = false

    // MARK: - Persistence

    static var configURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("MacSentinel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mcp-config.json")
    }

    /// Read the config from disk. Returns defaults if the file doesn't exist
    /// or fails to decode.
    static func load() -> MCPConfig {
        guard let data = try? Data(contentsOf: configURL),
              let cfg  = try? JSONDecoder().decode(MCPConfig.self, from: data)
        else { return MCPConfig() }
        return cfg
    }

    /// Persist this config to disk (pretty-printed for human inspection).
    func save() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(self)
        try data.write(to: Self.configURL, options: .atomic)
    }
}

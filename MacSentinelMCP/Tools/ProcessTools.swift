import Foundation

// MARK: - macsentinel.list_processes

struct ListProcessesTool: MCPToolHandler {
    let tool = MCPTool(
        name: "macsentinel.list_processes",
        description: """
            List currently running processes with PID, name, executable path, CPU %,
            RAM usage, parent PID, and bundle ID (for GUI apps). Read-only — does not
            kill any process. Use 'limit' to cap results and 'sort_by' = "cpu" or "memory"
            to focus on resource hogs.
            """,
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "limit": .object([
                    "type": .string("integer"),
                    "description": .string("Max number of processes to return (default 50, max 500)"),
                ]),
                "sort_by": .object([
                    "type": .string("string"),
                    "enum": .array([.string("cpu"), .string("memory"), .string("name")]),
                    "description": .string("Sort order (default 'cpu')"),
                ]),
            ]),
            "additionalProperties": .bool(false),
        ])
    )

    func call(arguments: JSONValue?) async throws -> MCPToolResult {
        let limit = min(500, max(1, extractInt(arguments, "limit") ?? 50))
        let sortBy = arguments?.string("sort_by") ?? "cpu"

        let processes = await ProcessSnapshotService.shared.snapshotOnce()
        let sorted: [ProcessInfo]
        switch sortBy {
        case "memory": sorted = processes.sorted { $0.memoryBytes > $1.memoryBytes }
        case "name":   sorted = processes.sorted { $0.name < $1.name }
        default:       sorted = processes.sorted { $0.cpuPercent > $1.cpuPercent }
        }

        struct ProcExport: Codable {
            let pid: Int32
            let name: String
            let executablePath: String
            let cpuPercent: Double
            let memoryMB: Double
            let parentPID: Int32
            let isGUIApp: Bool
            let bundleIdentifier: String?
        }
        struct ResponseEnvelope: Codable {
            let totalCount: Int
            let returned: Int
            let processes: [ProcExport]
        }

        let exportArray = sorted.prefix(limit).map { p in
            ProcExport(
                pid: p.id, name: p.name, executablePath: p.executablePath,
                cpuPercent: round(p.cpuPercent * 10) / 10,
                memoryMB: round(p.memoryMB * 10) / 10,
                parentPID: p.parentPID, isGUIApp: p.isGUIApp,
                bundleIdentifier: p.bundleIdentifier
            )
        }
        let envelope = ResponseEnvelope(
            totalCount: processes.count,
            returned: exportArray.count,
            processes: Array(exportArray)
        )
        return try toolJSONResult(envelope)
    }

    private func extractInt(_ value: JSONValue?, _ key: String) -> Int? {
        guard case .object(let o)? = value else { return nil }
        if case .int(let i) = o[key] { return i }
        if case .double(let d) = o[key] { return Int(d) }
        return nil
    }
}

import Foundation

// MARK: - MCP Server
//
// Reads line-delimited JSON-RPC messages from stdin, dispatches them to
// registered tool handlers, and writes responses to stdout. All human-readable
// logging MUST go to stderr (otherwise it corrupts the JSON-RPC channel).

protocol MCPToolHandler {
    var tool: MCPTool { get }
    func call(arguments: JSONValue?) async throws -> MCPToolResult
}

final class MCPServer {

    let serverName = "macsentinel"
    let serverVersion = "1.0.0"
    let protocolVersion = "2024-11-05"   // current MCP spec version

    private var tools: [String: MCPToolHandler] = [:]
    private let stdoutQueue = DispatchQueue(label: "macsentinel.mcp.stdout")

    func register(_ handler: MCPToolHandler) {
        tools[handler.tool.name] = handler
    }

    /// Main loop. Returns when stdin closes (parent process exits).
    func run() async {
        log("MacSentinel MCP server starting — \(tools.count) tools registered")

        // Use FileHandle.standardInput.bytes for async line reading
        let stdin = FileHandle.standardInput
        let buffer = AsyncLineReader(handle: stdin)

        for await line in buffer.lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            await handleLine(trimmed)
        }

        log("stdin closed — exiting")
    }

    private func handleLine(_ line: String) async {
        guard let data = line.data(using: .utf8) else {
            sendParseError()
            return
        }

        let req: JSONRPCRequest
        do {
            req = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        } catch {
            sendParseError()
            return
        }

        // Notifications (no id) — process but don't respond
        if req.id == nil {
            log("notification: \(req.method)")
            return
        }

        let response = await dispatch(req)
        send(response)
    }

    private func dispatch(_ req: JSONRPCRequest) async -> JSONRPCResponse {
        let id = req.id ?? .null

        switch req.method {
        case "initialize":
            return .success(id: id, result: initializeResult())
        case "initialized", "notifications/initialized":
            // The client signals it's done; no response needed for notifications,
            // but if we got here with an id, just ack with empty result.
            return .success(id: id, result: .object([:]))
        case "ping":
            return .success(id: id, result: .object([:]))
        case "tools/list":
            return .success(id: id, result: toolsListResult())
        case "tools/call":
            return await handleToolCall(id: id, params: req.params)
        case "resources/list", "prompts/list":
            // We don't expose resources or prompts (yet) — return empty.
            let key = req.method == "resources/list" ? "resources" : "prompts"
            return .success(id: id, result: .object([key: .array([])]))
        default:
            return .failure(id: id, code: MCPErrorCode.methodNotFound,
                            message: "Method not found: \(req.method)")
        }
    }

    private func initializeResult() -> JSONValue {
        .object([
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([
                "tools": .object(["listChanged": .bool(false)]),
            ]),
            "serverInfo": .object([
                "name":    .string(serverName),
                "version": .string(serverVersion),
            ]),
        ])
    }

    private func toolsListResult() -> JSONValue {
        let toolValues = tools.values.map { handler -> JSONValue in
            .object([
                "name":        .string(handler.tool.name),
                "description": .string(handler.tool.description),
                "inputSchema": handler.tool.inputSchema,
            ])
        }
        return .object(["tools": .array(toolValues)])
    }

    private func handleToolCall(id: JSONValue, params: JSONValue?) async -> JSONRPCResponse {
        guard let name = params?.string("name") else {
            return .failure(id: id, code: MCPErrorCode.invalidParams,
                            message: "Missing tool name")
        }
        guard let handler = tools[name] else {
            return .failure(id: id, code: MCPErrorCode.methodNotFound,
                            message: "Unknown tool: \(name)")
        }
        let args: JSONValue? = {
            guard case .object(let p)? = params else { return nil }
            return p["arguments"]
        }()

        do {
            let result = try await handler.call(arguments: args)
            let encoded = try jsonValueEncode(result)
            return .success(id: id, result: encoded)
        } catch let e as MCPToolError {
            return .failure(id: id, code: e.code, message: e.message)
        } catch {
            return .failure(id: id, code: MCPErrorCode.toolError,
                            message: error.localizedDescription)
        }
    }

    // MARK: - I/O

    private func send(_ resp: JSONRPCResponse) {
        do {
            let data = try JSONEncoder().encode(resp)
            stdoutQueue.sync {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data([0x0A]))   // newline
            }
        } catch {
            log("encode error: \(error)")
        }
    }

    private func sendParseError() {
        let resp = JSONRPCResponse.failure(id: .null,
                                          code: MCPErrorCode.parseError,
                                          message: "Parse error")
        send(resp)
    }
}

// MARK: - Errors

struct MCPToolError: Error {
    let code: Int
    let message: String
    static func params(_ msg: String)    -> MCPToolError { .init(code: MCPErrorCode.invalidParams, message: msg) }
    static func internalErr(_ msg: String) -> MCPToolError { .init(code: MCPErrorCode.internalError, message: msg) }
    static func tool(_ msg: String)      -> MCPToolError { .init(code: MCPErrorCode.toolError, message: msg) }
    static func protected(_ msg: String) -> MCPToolError { .init(code: MCPErrorCode.protectedPath, message: msg) }
    static func dryRun(_ msg: String)    -> MCPToolError { .init(code: MCPErrorCode.dryRunBlocked, message: msg) }
}

// MARK: - Deletion failure classification
//
// Used by trash_items to give the AI / user actionable suggestions when a
// deletion fails. Maps a low-level error (EACCES, EPERM) to one of 4
// categories with a concrete remediation hint.

enum DeletionFailureReason: String, Codable {
    case tccBlocked          // ~/Library/Containers/* — needs Full Disk Access
    case rootRequired        // /Library/LaunchDaemons/* — needs sudo / XPC Helper
    case maclACL             // /Applications/SomeAppFromAppStore — needs Finder
    case protectedByPolicy   // ProtectedPaths rejected this on purpose
    case unknownPermission   // generic EPERM with no obvious classification
    case unknown
}

struct DeletionFailureClassifier {
    /// Determine why a particular path/error failed and produce a suggestion.
    static func classify(path: String, error: Error?) -> (reason: DeletionFailureReason, suggestion: String) {
        let url = URL(fileURLWithPath: path)
        let nsErrorCode = (error as NSError?)?.code ?? 0
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path

        // /Library/* or /System/* → needs root via XPC Helper
        if path.hasPrefix("/Library/") || path.hasPrefix("/System/") || path.hasPrefix("/usr/") {
            return (.rootRequired,
                    "此路徑需要 root 權限。請使用 MacSentinel Privileged Helper（待實作），或在 Terminal 用 sudo 處理。")
        }

        // ~/Library/Containers/* → almost always TCC
        if path.hasPrefix("\(homeDir)/Library/Containers/") ||
           path.hasPrefix("\(homeDir)/Library/Group Containers/") {
            return (.tccBlocked,
                    "macOS App Sandbox/TCC 保護此 Container。請至「系統設定 → 隱私權與安全性 → 完整磁碟取用權」授予 Claude.app 或 MacSentinel.app FDA 權限後再試。")
        }

        // /Applications/*.app → likely com.apple.macl ACL
        if path.hasPrefix("/Applications/") && path.hasSuffix(".app") {
            if hasMACLAttribute(url) {
                return (.maclACL,
                        "此 App 帶有 com.apple.macl ACL（通常是 App Store 或 Finder 安裝的）。請改用 Finder 拖到垃圾桶，或讓 MacSentinel 走 osascript Finder 路徑（已自動處理）。")
            }
        }

        // ProtectedPaths blocked it
        if ProtectedPaths.isProtected(url) {
            return (.protectedByPolicy,
                    "此路徑在 MacSentinel 的不可變保護清單中（如 Keychains / Mail / Safari history）。本程式不會碰它，請手動處理。")
        }

        // EPERM-ish but unclassified
        if nsErrorCode == 257 /* NSFileWriteNoPermissionError */ ||
           nsErrorCode == 513 {
            return (.unknownPermission,
                    "權限不足。請確認執行 MacSentinel 的進程是否擁有此檔案的寫入權限。")
        }
        return (.unknown,
                "未知的失敗原因。原始錯誤：\(error?.localizedDescription ?? "(無)")")
    }

    /// Check whether a path has the `com.apple.macl` extended attribute
    /// (set by App Store installer / Finder copy → restricts deletion to those tools).
    static func hasMACLAttribute(_ url: URL) -> Bool {
        let path = url.path
        let size = path.withCString { cPath in
            listxattr(cPath, nil, 0, 0)
        }
        guard size > 0 else { return false }
        var buf = [CChar](repeating: 0, count: size)
        let actual = path.withCString { cPath in
            listxattr(cPath, &buf, size, 0)
        }
        guard actual > 0 else { return false }
        let data = Data(bytes: buf, count: actual)
        guard let str = String(data: data, encoding: .utf8) else { return false }
        // listxattr returns NUL-separated strings
        return str.split(separator: "\0").contains("com.apple.macl")
    }
}

// MARK: - JSONValue helpers

func jsonValueEncode<T: Encodable>(_ value: T) throws -> JSONValue {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(JSONValue.self, from: data)
}

/// Convenience builder for tool text responses.
func toolTextResult(_ text: String, isError: Bool = false) -> MCPToolResult {
    MCPToolResult(content: [MCPContent(type: "text", text: text)], isError: isError)
}

/// Encode any Encodable as a single text content block of pretty JSON.
func toolJSONResult<T: Encodable>(_ value: T) throws -> MCPToolResult {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    let data = try enc.encode(value)
    let text = String(data: data, encoding: .utf8) ?? "{}"
    return toolTextResult(text)
}

// MARK: - stderr logging

func log(_ message: String) {
    let line = "[macsentinel-mcp] \(message)\n"
    if let d = line.data(using: .utf8) {
        FileHandle.standardError.write(d)
    }
}

// MARK: - AsyncLineReader (stdin → AsyncSequence of lines)

final class AsyncLineReader {
    private let handle: FileHandle
    init(handle: FileHandle) { self.handle = handle }

    var lines: AsyncStream<String> {
        AsyncStream { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [handle] in
                var buffer = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        // Flush remaining buffer if any
                        if !buffer.isEmpty, let s = String(data: buffer, encoding: .utf8) {
                            continuation.yield(s)
                        }
                        continuation.finish()
                        return
                    }
                    buffer.append(chunk)
                    while let nl = buffer.firstIndex(of: 0x0A) {
                        let lineData = buffer.subdata(in: 0..<nl)
                        buffer.removeSubrange(0...nl)
                        if let s = String(data: lineData, encoding: .utf8) {
                            continuation.yield(s)
                        }
                    }
                }
            }
        }
    }
}

import Foundation

// MARK: - JSON-RPC 2.0 + MCP types
//
// MCP (Model Context Protocol) by Anthropic uses JSON-RPC 2.0 as its wire
// format. Spec: https://spec.modelcontextprotocol.io/specification/
//
// Servers receive line-delimited JSON-RPC messages on stdin and reply on
// stdout. stderr is reserved for human-readable logs.

// MARK: - Wire JSON

/// A value type that can represent any JSON value. Used for tool arguments.
indirect enum JSONValue: Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self)    { self = .bool(v); return }
        if let v = try? c.decode(Int.self)     { self = .int(v); return }
        if let v = try? c.decode(Double.self)  { self = .double(v); return }
        if let v = try? c.decode(String.self)  { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.typeMismatch(JSONValue.self,
            .init(codingPath: decoder.codingPath, debugDescription: "unsupported JSON value"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let v):    try c.encode(v)
        case .int(let v):     try c.encode(v)
        case .double(let v):  try c.encode(v)
        case .string(let v):  try c.encode(v)
        case .array(let v):   try c.encode(v)
        case .object(let v):  try c.encode(v)
        }
    }

    /// Convenience: read a String field from an object.
    func string(_ key: String) -> String? {
        guard case .object(let o) = self, case .string(let s) = o[key] else { return nil }
        return s
    }
    func bool(_ key: String) -> Bool? {
        guard case .object(let o) = self, case .bool(let b) = o[key] else { return nil }
        return b
    }
    func array(_ key: String) -> [JSONValue]? {
        guard case .object(let o) = self, case .array(let a) = o[key] else { return nil }
        return a
    }
}

// MARK: - Request / Response envelopes

struct JSONRPCRequest: Codable {
    let jsonrpc: String         // always "2.0"
    let id: JSONValue?          // null/missing = notification (no response)
    let method: String
    let params: JSONValue?
}

struct JSONRPCResponse: Codable {
    let jsonrpc: String         // always "2.0"
    let id: JSONValue
    let result: JSONValue?
    let error: JSONRPCError?

    static func success(id: JSONValue, result: JSONValue) -> JSONRPCResponse {
        .init(jsonrpc: "2.0", id: id, result: result, error: nil)
    }
    static func failure(id: JSONValue, code: Int, message: String) -> JSONRPCResponse {
        .init(jsonrpc: "2.0", id: id, result: nil,
              error: .init(code: code, message: message, data: nil))
    }
}

struct JSONRPCError: Codable {
    let code: Int
    let message: String
    let data: JSONValue?
}

// Standard error codes
enum MCPErrorCode {
    static let parseError      = -32700
    static let invalidRequest  = -32600
    static let methodNotFound  = -32601
    static let invalidParams   = -32602
    static let internalError   = -32603
    // Application-specific
    static let toolError       = -32000
    static let protectedPath   = -32001
    static let dryRunBlocked   = -32002
}

// MARK: - MCP-specific structures

struct MCPTool: Codable {
    let name: String
    let description: String
    let inputSchema: JSONValue   // JSON Schema describing the tool's arguments
}

struct MCPContent: Codable {
    let type: String             // "text"
    let text: String
}

/// What `tools/call` returns.
struct MCPToolResult: Codable {
    let content: [MCPContent]
    let isError: Bool?
}

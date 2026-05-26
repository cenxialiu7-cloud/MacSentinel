import Foundation

// MARK: - AIProvider
//
// Abstracts the chat completion call so the UI can swap between Anthropic
// (Claude) and a local Ollama server without caring about HTTP shape.
//
// Streaming is not implemented yet — `complete()` returns the full response.
// Both providers are stateless; the caller (ChatViewModel) keeps history.

struct ChatMessage: Identifiable, Codable, Hashable {
    enum Role: String, Codable { case user, assistant, system }
    let id: UUID
    let role: Role
    var content: String
    let timestamp: Date

    init(role: Role, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
    }
}

enum AIProviderKind: String, Codable, CaseIterable {
    case anthropic = "Anthropic (Claude)"
    case ollama    = "Ollama (本機)"
}

protocol AIProvider {
    func complete(messages: [ChatMessage], system: String?) async throws -> String
}

// MARK: - Anthropic

struct AnthropicProvider: AIProvider {
    let apiKey: String
    let model: String

    func complete(messages: [ChatMessage], system: String?) async throws -> String {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var req = URLRequest(url: url, timeoutInterval: 60)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
            "messages": messages.filter { $0.role != .system }.map {
                ["role": $0.role.rawValue, "content": $0.content]
            },
        ]
        if let system = system, !system.isEmpty { body["system"] = system }

        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "AIProvider", code: 0,
                          userInfo: [NSLocalizedDescriptionKey: "Bad response"])
        }
        if http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? "(empty)"
            throw NSError(domain: "AIProvider", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else {
            throw NSError(domain: "AIProvider", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot parse response"])
        }
        let text = content.compactMap { $0["text"] as? String }.joined()
        return text.isEmpty ? "(empty response)" : text
    }
}

// MARK: - Ollama

struct OllamaProvider: AIProvider {
    let endpoint: URL    // typically http://localhost:11434
    let model: String

    func complete(messages: [ChatMessage], system: String?) async throws -> String {
        let url = endpoint.appendingPathComponent("api/chat")
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var msgs: [[String: String]] = []
        if let system = system, !system.isEmpty {
            msgs.append(["role": "system", "content": system])
        }
        for m in messages {
            msgs.append(["role": m.role.rawValue, "content": m.content])
        }

        let body: [String: Any] = [
            "model": model,
            "messages": msgs,
            "stream": false,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            let snippet = String(data: data, encoding: .utf8)?.prefix(200) ?? ""
            throw NSError(domain: "AIProvider", code: code,
                          userInfo: [NSLocalizedDescriptionKey: "Ollama HTTP \(code): \(snippet)"])
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg  = json["message"] as? [String: Any],
              let text = msg["content"] as? String
        else {
            throw NSError(domain: "AIProvider", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot parse Ollama response"])
        }
        return text
    }
}

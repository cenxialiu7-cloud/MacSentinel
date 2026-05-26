import SwiftUI

// MARK: - ChatView
//
// Lightweight chat surface that lets the user talk to an LLM (Anthropic
// Claude API or a local Ollama server). The model has no access to
// MacSentinel's MCP tools yet — that wiring is intentionally out of scope
// for the first cut. This view exists so users have a single window to:
//
//   1. Ask "what should I clean?" without leaving the app
//   2. Paste scan output and get a triage
//   3. Run quick security Q&A against their own findings
//
// The conversation lives in memory only — closing the window clears it.

@Observable
final class ChatViewModel {
    var messages: [ChatMessage] = []
    var input: String = ""
    var isSending: Bool = false
    var errorMessage: String?

    func send(provider: AIProvider, system: String?) async {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSending else { return }
        messages.append(ChatMessage(role: .user, content: text))
        input = ""
        isSending = true
        errorMessage = nil
        do {
            let reply = try await provider.complete(messages: messages, system: system)
            messages.append(ChatMessage(role: .assistant, content: reply))
        } catch {
            errorMessage = error.localizedDescription
        }
        isSending = false
    }

    func reset() {
        messages.removeAll()
        errorMessage = nil
    }
}

struct ChatView: View {
    @AppStorage("ai.provider")     private var providerRaw: String = AIProviderKind.anthropic.rawValue
    @AppStorage("ai.anthropicModel") private var anthropicModel: String = "claude-opus-4-7"
    @AppStorage("ai.ollamaEndpoint") private var ollamaEndpoint: String = "http://localhost:11434"
    @AppStorage("ai.ollamaModel")    private var ollamaModel: String    = "llama3.2"

    @State private var vm = ChatViewModel()
    @State private var apiKey: String = Keychain.get("anthropic-api-key") ?? ""
    @State private var showSettings = false

    private var providerKind: AIProviderKind {
        AIProviderKind(rawValue: providerRaw) ?? .anthropic
    }

    private var canSend: Bool {
        if vm.isSending { return false }
        if vm.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        switch providerKind {
        case .anthropic: return !apiKey.isEmpty
        case .ollama:    return true
        }
    }

    private let systemPrompt = """
        你是 MacSentinel 內建的 AI 助理。MacSentinel 是一款 macOS 系統優化與安全工具，會掃描快取、應用程式殘留、可疑進程、瀏覽器擴充與網路設定。回答時：
        1. 中文回覆，簡潔具體。
        2. 涉及刪除操作時，務必提醒使用者保留 Time Machine 備份或先用 dry-run。
        3. 不要捏造路徑或檔名。
        """

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if vm.messages.isEmpty { emptyState } else { messagesScroll }
            Divider()
            inputBar
        }
        .navigationTitle("AI 助理")
        .sheet(isPresented: $showSettings) { settingsSheet }
    }

    private var header: some View {
        HStack {
            Label(providerKind.rawValue, systemImage: "sparkles")
                .font(.callout)
            Spacer()
            Button("設定") { showSettings = true }
                .buttonStyle(.borderless)
            Button("清除") { vm.reset() }
                .buttonStyle(.borderless)
                .disabled(vm.messages.isEmpty)
        }
        .padding(10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("和 AI 助理討論你的 Mac 健康狀況")
                .font(.headline)
            Text(providerKind == .anthropic && apiKey.isEmpty
                 ? "請先在「設定」貼上 Anthropic API Key。"
                 : "輸入下方訊息開始對話。對話內容只存在記憶體中。")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var messagesScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(vm.messages) { msg in
                        ChatBubble(message: msg).id(msg.id)
                    }
                    if let err = vm.errorMessage {
                        Text(err).font(.caption).foregroundStyle(.red)
                            .padding(.horizontal)
                    }
                }
                .padding()
            }
            .onChange(of: vm.messages.count) {
                if let last = vm.messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("問點什麼…", text: $vm.input, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .onSubmit { Task { await trySend() } }

            Button {
                Task { await trySend() }
            } label: {
                if vm.isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canSend)
        }
        .padding(10)
    }

    private func trySend() async {
        guard let provider = makeProvider() else {
            vm.errorMessage = "請先在設定中填入 API Key 或 Ollama Endpoint。"
            return
        }
        await vm.send(provider: provider, system: systemPrompt)
    }

    private func makeProvider() -> AIProvider? {
        switch providerKind {
        case .anthropic:
            guard !apiKey.isEmpty else { return nil }
            return AnthropicProvider(apiKey: apiKey, model: anthropicModel)
        case .ollama:
            guard let url = URL(string: ollamaEndpoint) else { return nil }
            return OllamaProvider(endpoint: url, model: ollamaModel)
        }
    }

    // MARK: - Settings sheet

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("AI 助理設定").font(.title2.bold())
                Spacer()
                Button("關閉") { showSettings = false }
            }

            Picker("提供者", selection: $providerRaw) {
                ForEach(AIProviderKind.allCases, id: \.rawValue) { k in
                    Text(k.rawValue).tag(k.rawValue)
                }
            }
            .pickerStyle(.segmented)

            if providerKind == .anthropic {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Anthropic API Key").font(.caption.bold())
                    SecureField("sk-ant-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: apiKey) {
                            if apiKey.isEmpty {
                                Keychain.remove("anthropic-api-key")
                            } else {
                                Keychain.set(apiKey, for: "anthropic-api-key")
                            }
                        }
                    Text("存於 macOS 鑰匙圈，僅本 App 可讀。").font(.caption2).foregroundStyle(.secondary)
                }
                LabeledContent("模型") {
                    TextField("model", text: $anthropicModel)
                        .textFieldStyle(.roundedBorder)
                }
            } else {
                LabeledContent("Endpoint") {
                    TextField("http://localhost:11434", text: $ollamaEndpoint)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("模型") {
                    TextField("llama3.2", text: $ollamaModel)
                        .textFieldStyle(.roundedBorder)
                }
                Text("需要本機 Ollama 服務正在執行。").font(.caption2).foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 460, height: 360)
    }
}

// MARK: - Bubble

struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                Text(message.content)
                    .textSelection(.enabled)
                    .padding(10)
                    .background(bubbleColor, in: RoundedRectangle(cornerRadius: 10))
                    .foregroundStyle(message.role == .user ? .white : .primary)
            }
            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user:      return .accentColor
        case .assistant: return Color(NSColor.controlBackgroundColor)
        case .system:    return Color.yellow.opacity(0.2)
        }
    }
}

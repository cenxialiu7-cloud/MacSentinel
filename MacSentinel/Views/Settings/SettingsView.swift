import SwiftUI

struct SettingsView: View {
    @AppStorage("cpuWarningThreshold")    private var cpuWarning: Double    = 80
    @AppStorage("memWarningThreshold")    private var memWarning: Double    = 85
    @AppStorage("tempWarningThreshold")   private var tempWarning: Double   = 85
    @AppStorage("sampleInterval")         private var sampleInterval: Double = 2
    @AppStorage("launchAtLogin")          private var launchAtLogin: Bool   = false
    @AppStorage(MonetizationConfig.showSponsorMessagesKey)
    private var showSponsorMessages: Bool = true

    // MCP server state, persisted to disk via MCPConfig
    @State private var mcpConfig: MCPConfig = MCPConfig.load()
    @State private var showAttribution = false
    @State private var showMCPSetup    = false

    // Privileged Helper
    @State private var helper = PrivilegedHelperConnection.shared
    @State private var helperError: String?

    // Browser blocklist feed
    @State private var blocklistCount: Int = BrowserBlocklistFeed.shared.remoteEntries.count
    @State private var blocklistUpdated: Date = BrowserBlocklistFeed.shared.lastUpdated
    @State private var blocklistRefreshing = false
    @State private var blocklistError: String?

    var body: some View {
        Form {
            Section("監控設定") {
                LabeledContent("採樣間隔") {
                    Slider(value: $sampleInterval, in: 1...10, step: 1)
                    Text("\(Int(sampleInterval)) 秒").frame(width: 40)
                }
                LabeledContent("CPU 警告閾值") {
                    Slider(value: $cpuWarning, in: 50...99, step: 5)
                    Text("\(Int(cpuWarning))%").frame(width: 40)
                }
                LabeledContent("記憶體警告閾值") {
                    Slider(value: $memWarning, in: 60...99, step: 5)
                    Text("\(Int(memWarning))%").frame(width: 40)
                }
                LabeledContent("溫度警告閾值") {
                    Slider(value: $tempWarning, in: 70...110, step: 5)
                    Text("\(Int(tempWarning))°C").frame(width: 40)
                }
            }

            Section("啟動") {
                Toggle("登入時自動啟動", isOn: $launchAtLogin)
            }

            // ── MCP Server (本機 AI 助理整合) ───────────────────────────────
            Section {
                Toggle("啟用 MCP Server", isOn: $mcpConfig.enabled)
                    .onChange(of: mcpConfig.enabled) { saveMCPConfig() }

                if mcpConfig.enabled {
                    Toggle(isOn: $mcpConfig.allowRealDelete) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("允許 AI 直接執行刪除")
                            Text("關閉時（預設）AI 只能模擬掃描與「dry-run」報告，不會真的移除任何檔案。")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .onChange(of: mcpConfig.allowRealDelete) { saveMCPConfig() }

                    Button("顯示連線設定指引") { showMCPSetup = true }
                        .buttonStyle(.borderless)
                }
            } header: {
                HStack {
                    Text("AI 助理整合（MCP Server）")
                    Spacer()
                    Text("Beta").font(.caption2).foregroundStyle(.orange)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("讓本機 AI 助理（Claude Code、Cursor、Cowork 等）可以呼叫 MacSentinel 掃描與安全清除功能。資料不會離開你的 Mac。")
                    Text("所有刪除仍走 SafeDeleteService → 垃圾桶；受保護路徑永不開放。")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption2)
            }

            // ── Privileged Helper (root daemon for system-protected paths) ──
            Section {
                HStack {
                    Circle()
                        .fill(helperStatusColor)
                        .frame(width: 8, height: 8)
                    Text(helperStatusText)
                        .font(.callout)
                    Spacer()
                    if let v = helper.helperVersion {
                        Text("v\(v)").font(.caption2).foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    switch helper.installStatus {
                    case .notInstalled, .notFound:
                        Button("註冊 Privileged Helper") { installHelper() }
                            .buttonStyle(.borderedProminent)
                    case .requiresApproval:
                        Button("開啟「登入項目與背景擴充功能」") {
                            helper.openLoginItemsSettings()
                        }
                        .buttonStyle(.borderedProminent)
                        Button("重新檢查狀態") { helper.refreshStatus() }
                    case .installed:
                        Button("移除 Helper") { uninstallHelper() }
                            .tint(.red)
                        Button("重新檢查狀態") { helper.refreshStatus() }
                    }
                }

                if let err = helperError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            } header: {
                Text("Privileged Helper")
            } footer: {
                Text("""
                    Helper 是一個 root 權限的 XPC daemon，用於處理需要管理員權限才能刪除的路徑（如 /Library/LaunchAgents、舊版 kext、被 com.apple.macl 鎖住的應用程式）。安裝後 macOS 會要求你在「系統設定 → 一般 → 登入項目與背景擴充功能」核可。Helper 拒絕觸碰 /System、/usr、/bin 等系統關鍵路徑，所有操作都會寫入 audit log。
                    """)
                    .font(.caption2)
            }

            // ── Browser Blocklist (remote feed) ────────────────────────────
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(blocklistCount) 條遠端條目").font(.callout)
                        Text(blocklistUpdated == .distantPast
                             ? "尚未下載過"
                             : "上次更新：\(blocklistUpdated.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await refreshBlocklist() }
                    } label: {
                        if blocklistRefreshing { ProgressView().controlSize(.small) }
                        else { Text("立即更新") }
                    }
                    .disabled(blocklistRefreshing)
                }
                if let err = blocklistError {
                    Text(err).font(.caption2).foregroundStyle(.red)
                }
            } header: {
                Text("瀏覽器擴充黑名單")
            } footer: {
                Text("從 Mozilla 公開的 blocklist 拉取惡意擴充 ID。本機快取 24 小時，與 MacSentinel 內建 4 條 IOC 合併使用。")
                    .font(.caption2)
            }

            Section("資料管理") {
                LabeledContent("Audit Log") {
                    Button("開啟日誌檔案") { openAuditLog() }
                        .buttonStyle(.borderless)
                }
                LabeledContent("MCP 設定檔") {
                    Button("在 Finder 顯示") { openMCPConfigInFinder() }
                        .buttonStyle(.borderless)
                }
            }

            // ── 掃描白名單（使用者自訂永不掃路徑）──────────────────────
            Section {
                WhitelistEditor()
            } header: {
                Text("掃描白名單")
            } footer: {
                Text("加入此處的路徑（含子目錄）將不會出現在快取、大檔/舊檔、重複檔案任何掃描結果中。系統保護路徑由 MacSentinel 內建，無法停用。")
                    .font(.caption2)
            }

            // ── 支援與贊助 ─────────────────────────────────────────────
            Section {
                Toggle("顯示贊助商訊息", isOn: $showSponsorMessages)
                    .help("關閉後，Dashboard 頂部的 VPN / 合作夥伴橫幅將不再顯示。")

                if let offer = MonetizationConfig.primaryVPNOffer, let url = offer.url {
                    LabeledContent(offer.headline) {
                        Link(offer.ctaTitle, destination: url)
                            .font(.callout)
                    }
                }

                if let kofi = MonetizationConfig.donationURL {
                    LabeledContent("贊助開發") {
                        Link("☕ Ko-fi", destination: kofi)
                            .font(.callout)
                    }
                }
            } header: {
                Text("支援與贊助")
            } footer: {
                Text("MacSentinel 完全免費且開放原始碼。若覺得有用，可以透過上述連結支持持續開發；所有外連點擊都會透過你的預設瀏覽器開啟，App 本身不載入任何第三方追蹤腳本。")
                    .font(.caption2)
            }

            Section("關於") {
                LabeledContent("版本", value: "MacSentinel 1.1.3")
                LabeledContent("最低系統", value: "macOS 14.0 Sonoma")
                LabeledContent("架構", value: "Swift 5.10 · SwiftUI · IOKit · MCP")
                Button("開源致謝與授權") { showAttribution = true }
                    .buttonStyle(.borderless)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("設定")
        .frame(width: 540, height: 620)
        .sheet(isPresented: $showAttribution) { AttributionSheet() }
        .sheet(isPresented: $showMCPSetup)    { MCPSetupSheet() }
    }

    // MARK: - Helpers

    private func saveMCPConfig() {
        do { try mcpConfig.save() }
        catch { NSLog("Failed to save MCPConfig: \(error)") }
    }

    private func openAuditLog() {
        let appSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacSentinel/audit.log")
        NSWorkspace.shared.open(appSupport)
    }

    // MARK: - Privileged Helper actions

    private var helperStatusText: String {
        switch helper.installStatus {
        case .notInstalled:     return "尚未註冊"
        case .requiresApproval: return "已註冊 — 需要至「登入項目」核可"
        case .installed:        return "已啟用"
        case .notFound:         return "找不到 Helper 二進位（請重新安裝 App）"
        }
    }

    private var helperStatusColor: Color {
        switch helper.installStatus {
        case .installed:        return .green
        case .requiresApproval: return .orange
        case .notInstalled:     return .secondary
        case .notFound:         return .red
        }
    }

    private func installHelper() {
        helperError = nil
        do {
            let status = try helper.install()
            if status == .requiresApproval {
                helper.openLoginItemsSettings()
            }
        } catch {
            helperError = "註冊失敗：\(error.localizedDescription)"
        }
    }

    private func uninstallHelper() {
        helperError = nil
        do { try helper.uninstall() }
        catch { helperError = "移除失敗：\(error.localizedDescription)" }
    }

    private func refreshBlocklist() async {
        blocklistRefreshing = true
        blocklistError = nil
        let count = await BrowserBlocklistFeed.shared.refresh()
        blocklistCount = count
        blocklistUpdated = BrowserBlocklistFeed.shared.lastUpdated
        blocklistError = BrowserBlocklistFeed.shared.lastRefreshError
        blocklistRefreshing = false
    }

    private func openMCPConfigInFinder() {
        // Make sure the file exists before opening Finder
        try? mcpConfig.save()
        NSWorkspace.shared.activateFileViewerSelecting([MCPConfig.configURL])
    }
}

// MARK: - MCP Setup Sheet

struct MCPSetupSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Path the user should plug into their MCP client's config.
    /// Inside a packaged .app this is .../MacSentinel.app/Contents/MacOS/macsentinel-mcp
    private var binaryPath: String {
        let bundle = Bundle.main.bundlePath
        return bundle + "/Contents/MacOS/macsentinel-mcp"
    }

    private var claudeCodeConfigSnippet: String {
        """
        {
          "mcpServers": {
            "macsentinel": {
              "command": "\(binaryPath)",
              "args": []
            }
          }
        }
        """
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Label("MCP Server 連線設定", systemImage: "link.circle.fill")
                        .font(.title2.bold())
                    Spacer()
                    Button("關閉") { dismiss() }
                }

                Text("MacSentinel 內附一個叫 `macsentinel-mcp` 的 CLI 工具，遵循 Model Context Protocol。任何支援 MCP 的本機 AI 助理都可以連上它，呼叫掃描與清除功能 —— 不需要 API Key，資料不會離開你的 Mac。")
                    .font(.callout)

                Divider()

                Group {
                    Text("二進制位置").font(.headline)
                    HStack {
                        Text(binaryPath)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(binaryPath, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help("複製路徑")
                    }
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                }

                Group {
                    Text("Claude Code 設定").font(.headline)
                    Text("把下方 JSON 加到 `~/.config/claude-code/mcp_settings.json` 或於設定頁的「MCP Servers」欄位輸入。")
                        .font(.caption).foregroundStyle(.secondary)

                    Text(claudeCodeConfigSnippet)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

                    Button("複製 JSON 設定") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(claudeCodeConfigSnippet, forType: .string)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Divider()

                Group {
                    Text("可用工具").font(.headline)
                    VStack(alignment: .leading, spacing: 6) {
                        toolRow("list_capabilities", "唯讀", "列出所有工具、目前模式、保護路徑清單")
                        toolRow("scan_caches",       "唯讀", "掃描可清除的快取（6 大類）")
                        toolRow("scan_apps",         "唯讀", "已安裝 App 與殘留檔案")
                        toolRow("scan_migration",    "唯讀", "舊資料 / 孤兒項目 / 不相容 kext")
                        toolRow("list_processes",    "唯讀", "目前運行的行程清單")
                        toolRow("read_audit_log",    "唯讀", "讀取近期操作紀錄")
                        toolRow("trash_items",       "寫入", "把指定路徑移到垃圾桶（受保護路徑會拒絕）")
                    }
                }

                Divider()

                Group {
                    Text("安全設計").font(.headline)
                    VStack(alignment: .leading, spacing: 4) {
                        BulletItem(icon: "1.circle.fill", color: .blue,
                                   text: "預設為 dry-run 模式 —— AI 即使呼叫 trash_items 也只會回報「會刪什麼」，不會真的刪。")
                        BulletItem(icon: "2.circle.fill", color: .blue,
                                   text: "勾選「允許 AI 直接執行刪除」才會真實移到垃圾桶（仍可從垃圾桶還原）。")
                        BulletItem(icon: "3.circle.fill", color: .blue,
                                   text: "受保護路徑（家目錄、Documents、Desktop、Downloads、Keychain、Mail、Safari、Messages、iCloud…）無論如何都會被擋。")
                        BulletItem(icon: "4.circle.fill", color: .blue,
                                   text: "每筆操作都會記錄在 audit log，標註 caller=mcp 或 mcp-dryrun，可隨時稽核。")
                    }
                }

                Divider()

                Group {
                    Text("試用範例提示語").font(.headline)
                    Text("在 Claude Code 中可以這樣問：")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("「幫我用 MacSentinel 掃描快取，列出可以安全清除的瀏覽器快取，總計多少 GB？」\n\n「找出我電腦上所有 Intel-only 的 App，按大小排序。」\n\n「列出 CPU 用量最高的前 10 個行程。」")
                        .font(.callout)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(20)
        }
        .frame(width: 640, height: 720)
    }

    @ViewBuilder
    private func toolRow(_ name: String, _ tag: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("macsentinel.\(name)")
                .font(.system(.caption, design: .monospaced).bold())
                .frame(width: 220, alignment: .leading)
            Text(tag)
                .font(.caption2.bold())
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background((tag == "寫入" ? Color.red : Color.green).opacity(0.15), in: Capsule())
                .foregroundStyle(tag == "寫入" ? .red : .green)
            Text(desc).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
    }
}

// MARK: - Attribution Sheet (Open-source credits)

struct AttributionSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("開源致謝與授權").font(.title2.bold())
                Spacer()
                Button("關閉") { dismiss() }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("MacSentinel 在設計與實作過程中參考了以下開源專案的架構與經驗。所有引用皆為「概念與架構參考」，並未直接複製程式碼。")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    Divider()

                    AttributionItem(
                        title: "Mole",
                        author: "tw93 (GitHub)",
                        license: "MIT",
                        url: "https://github.com/tw93/mole",
                        notes: "CLI App 完整移除工具（Go + Shell）。參考其 dry-run 安全架構、22 條 App 殘留路徑、bundle ID + 名稱雙重比對策略。"
                    )

                    AttributionItem(
                        title: "Stats",
                        author: "exelban (GitHub)",
                        license: "MIT",
                        url: "https://github.com/exelban/stats",
                        notes: "macOS Menu Bar 系統監控（Swift + IOKit/SMC）。參考其 SMC bridging、Apple Silicon HID 溫度感測手法（IOHIDEventSystemClient）。"
                    )

                    AttributionItem(
                        title: "Model Context Protocol",
                        author: "Anthropic",
                        license: "MIT",
                        url: "https://spec.modelcontextprotocol.io/",
                        notes: "本工具的 MCP Server 實作遵循 MCP 規格（JSON-RPC 2.0 over stdio）。"
                    )

                    AttributionItem(
                        title: "AppCleaner（概念）",
                        author: "FreeMacSoft",
                        license: "Freeware",
                        url: "https://freemacsoft.net/appcleaner/",
                        notes: "macOS 老牌 App 卸載工具，產品設計參考。"
                    )

                    AttributionItem(
                        title: "CleanMyMac / iStatMenus（產品設計參考）",
                        author: "MacPaw / Bjango",
                        license: "Commercial",
                        url: nil,
                        notes: "商業工具的 UI/UX 設計參考。本專案未使用其程式碼。"
                    )

                    Divider()

                    Text("Apple 系統 API")
                        .font(.headline)
                    Text("IOKit, SMC, IOHIDEventSystem (private), Mach (host_processor_info, vm_statistics64, proc_pidinfo), AppKit (NSWorkspace), SwiftUI, Swift Charts.")
                        .font(.caption).foregroundStyle(.secondary)

                    Divider()

                    Text("MacSentinel 本身的所有掃描規則、安全分類邏輯、UI 設計、MCP 工具與 Swift 程式碼皆為原創。")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(20)
        .frame(width: 560, height: 580)
    }
}

// MARK: - Whitelist editor

struct WhitelistEditor: View {
    @State private var list = UserWhitelist.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if list.paths.isEmpty {
                Text("目前沒有自訂白名單。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(list.paths, id: \.self) { p in
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text(p)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            list.remove(p)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .help("移除")
                    }
                }
            }

            HStack {
                Button {
                    pickFolderToAdd()
                } label: {
                    Label("加入資料夾…", systemImage: "plus")
                }
                .controlSize(.small)
                Spacer()
                if !list.paths.isEmpty {
                    Button("全部清除") { list.reset() }
                        .controlSize(.small)
                        .tint(.red)
                }
            }
        }
    }

    private func pickFolderToAdd() {
        let panel = NSOpenPanel()
        panel.title = "選擇要加入白名單的資料夾"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            list.add(url.path)
        }
    }
}

struct AttributionItem: View {
    let title: String
    let author: String
    let license: String
    let url: String?
    let notes: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.headline)
                Text(license)
                    .font(.caption2.bold())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Color.blue.opacity(0.15), in: Capsule())
                    .foregroundStyle(.blue)
                Spacer()
                if let url = url {
                    Link("GitHub →", destination: URL(string: url)!)
                        .font(.caption)
                }
            }
            Text("by \(author)").font(.caption).foregroundStyle(.secondary)
            Text(notes).font(.caption).foregroundStyle(.secondary).padding(.top, 2)
        }
        .padding(10)
        .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}

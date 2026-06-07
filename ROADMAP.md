# MacSentinel ROADMAP — post-1.1.8

> 來源：2026-06-07 的研究 workflow（5 lens × 平行搜尋 + judge 排名 + 5 picks 對抗式 verify）。
> 每項都已通過：(a) value × feasibility 雙軸打分；(b) 對抗審查是否真實 / 新穎 / API 在 macOS 14 可用 / 部署風險。
> 維護慣例：實作前再跑一次 adversarial verify（避免 API 在新版 macOS 退化）。

---

## 🚢 SHIP（驗證乾淨、可下個版本直接做）

### 1. Loopback MCP tool calling — Chat 內呼叫 17 個工具
- **value 10 / feasibility 9 / combined 19**
- 來源：Raycast AI Extensions、Granola MCP、SwiftMCP
- **產品價值**：把 MacSentinel 從「按鈕工具」升級為「agent」。聊天介面已存在、17 個 MCP 工具已有 JSON schema —— 這是把它們拼起來。
- **實作 hint**：建立 `MCPLoopbackBridge`，把每個既有 MCP 工具註冊成 Anthropic/Ollama 的 tool-use schema；在進程內跑 tool_use/tool_result loop。對破壞性工具（`trash_items`、`kill_process`）強制 `dry_run=true` 直到使用者按 Approve。
- **Adversarial caveat**：複雜度被低估（M→L）。MCP handler 目前在獨立 binary（`MacSentinelMCP/main.swift`），要先重構成共用 library target 讓 App 能 in-process 呼叫。預估 +1-2 天。

### 2. AsyncSequence 串流 ChatView
- **value 8 / feasibility 10 / combined 18**
- 來源：Anthropic Swift SDK / SwiftAnthropic
- **產品價值**：tool-call UI chip 的硬前提（要在 stream 中段顯示「calling scan_caches…」）。Anthropic + Ollama 都已支援 SSE/NDJSON 串流。
- **實作 hint**：把 `ChatViewModel.sendMessage` 從 `await client.complete` 改成 `for try await chunk in client.stream`，append 進 `@Observable Message.content`。包進 cancellable Task 支援 Stop 按鈕。
- **Adversarial caveat**：複雜度低估（S→M）。需要兩套 parser（Anthropic SSE event types vs Ollama NDJSON）、mid-stream error 處理（Anthropic HTTP 200 + error event）、Task 取消策略。

### 7. `scan_dyld_inserts` — DYLD_INSERT_LIBRARIES 持久化偵測
- **value 8 / feasibility 10 / combined 18**
- 來源：KnockKnock（Objective-See）
- **產品價值**：經典 dyld-injection 持久化向量，`scan_login_items` 沒覆蓋到。免費延伸現有 `LoginItemsScanner`。
- **實作 hint**：解析 LaunchAgent/Daemon plist 時順手檢查 `EnvironmentVariables` dict 內 `DYLD_INSERT_LIBRARIES` / `DYLD_FRAMEWORK_PATH` / `DYLD_LIBRARY_PATH`。再掃 shell rc 找 `export DYLD_*`。新 MCP 工具 `scan_dyld_inserts`。

### 8. 拖放解除 quarantine + ad-hoc 重簽
- **value 8 / feasibility 9 / combined 17**
- 來源：Sentinel.app (alienator88)
- **產品價值**：「安全掃描器 + 幫你跑被擋的 OSS」是個獨特組合。OSS 使用者強烈口碑功能。
- **實作 hint**：`QuarantineService.swift`：`removexattr(path, "com.apple.quarantine", 0)` + `/usr/bin/codesign --force --deep --sign -`。`Views/Security` 加 drop target。MCP 工具 `unquarantine_app` + `adhoc_sign_app`，都遵守 `set_dry_run` gating。

### 9. 開發者環境快取（Xcode/node_modules/pip…）— 已大部分完成
- **value 8 / feasibility 10 / combined 18**
- **狀態**：CacheScanner 已包含 Xcode DerivedData、CocoaPods、Homebrew、pip、npm、yarn、Gradle、Playwright、iOS DeviceSupport、Simulator。**這項基本上 1.1.7 已實作**，僅缺：`node_modules` 樹級掃描（per project，可選擇性清掉）、Rust `target/`、Go `~/go/pkg/mod`。

### 10. MCP Resources — 把 scan 產物 expose 成 Resources
- **value 8 / feasibility 9 / combined 17**
- 來源：MCP spec 2025-11-25
- **產品價值**：直接加乘 #1（loopback chat）。Agent 可以重讀上次掃描結果，不必每輪重跑昂貴掃描。對 Ollama 使用者省 token。
- **實作 hint**：填滿 `MCPServer.swift` 的 `resources/list` stub。expose `macsentinel://audit/recent`、`macsentinel://scan/last-cache-scan`、`macsentinel://scan/last-hosts-diff` 等穩定 URI。

---

## ⏳ DEFER（真實但有重大隱藏成本）

### 3. `scan_tcc_permissions` — TCC.db 唯讀稽核
- combined=18，但 verify 發現 **使用者 TCC.db 也需要 FDA**（不只 root）。連帶 csreq blob 格式跨版本不穩定。
- **降低風險替代方案**：做「permission pane launcher」深連結到 `x-apple.systempreferences:com.apple.preference.security?Privacy_Camera` 等，解決 60% UX 問題用 5% 工程成本。

### 4. `scan_outdated_apps` — Sparkle feed + MAS receipt
- 經驗檢查：使用者 `/Applications` 內 40 個 app **只有 1 個有 SUFeedURL**（MacSentinel 本身）。Chrome / Brave / Firefox / Slack / Discord / Spotify / Office 都用 Omaha/KSUpdateURL 或專屬 updater，**不是 Sparkle**。
- **降低風險替代方案**：誠實地降範圍為「Sparkle-only updater status」，或拉長範圍涵蓋 Omaha + iTunes Search API + `brew outdated`（複雜度其實是 L 不是 M）。

### 5. `scan_persistence_unix` — UNIX 持久化掃描
- **macOS 14 已移除 emond**（連 binary 和 `/etc/emond.d` 都沒了）→ 寫進去等於 ship 死碼。`LoginHook`/`LogoutHook` 從 10.4 起 deprecated。`/etc/crontab` 與 `/etc/periodic` 在現代 macOS 預設不存在（出現本身就是異常 → 這個 angle 還是可用）。
- 最大目標 shell-rc 用「非 Apple owner」判式會誤判（owner 永遠是 user）。需 content-based heuristic（`curl|sh`、`base64`、`eval`、`wget`），否則 Homebrew / nvm / pyenv 安裝會大量 false positive。
- **重新評分**：scope 修正後 value=6 feasibility=6，不是 9/9。

### 6. Smart Uninstaller — 52 路徑殘留掃描
- combined=17。實作上要維護一份 52 路徑清單（App Support、Caches、Preferences、Containers、Group Containers、LaunchAgents/Daemons、WebKit、Cookies、Saved App State、plugins、kexts），key on `CFBundleIdentifier`。
- AppUninstallerView 目前的清單較短。值得做但 scope = M。

---

## ❌ REJECTED（不做或低 ROI）— 共 56 個，舉幾個關鍵

- **SMC sensor dashboard**：純 UI 拋光，不增能力
- **Per-process powermetrics**：要 root + Energy service 已涵蓋
- **Trash-drop FSEvents auto-cleanup**：背景常駐成本高，Pearcleaner 已佔位
- **App lipo（剝 universal binary）**：會破壞 codesign + 該 app 的 Sparkle 更新
- **Battery health controller**：拉進 BatFi 領域，SMC writes 每代不同
- **Pareto-style 30 項 hardening checklist**：L 複雜度且 Pareto Security 已免費做了
- **One-click Stronghold lockdown**：高破壞半徑（鎖死 SSH/screen sharing），客服災難

完整 56 項 rejected 清單在 git history 的 research workflow 結果中。

---

## 建議實作順序

| 階段 | 內容 | 預估 |
|---|---|---|
| **v1.1.9** | #7 `scan_dyld_inserts`（最小、最高 signal） | 1 day |
| **v1.2.0** | #2 streaming chat + #10 MCP Resources | 1 week |
| **v1.3.0** | #1 loopback MCP tool calling（agent 模式） | 1-2 weeks |
| **v1.4.0** | #8 quarantine helper + #6 Smart Uninstaller | 1 week |
| **defer** | #3 TCC scan（等 macOS 私有 API 穩定）、#4 outdated apps（先收集 KSUpdateURL 對照表）、#5 persistence unix（先研究內容啟發式） | — |

# MacSentinel — New Session Handoff Prompt

> 把這個檔案的 **內容全部複製貼到新 chat session** 即可讓新 Claude 完整理解此專案目前狀態並繼續開發。

---

## 你接手的是什麼

**MacSentinel** 是一款原生 macOS 系統優化 + 安全工具。Swift 5.10 / SwiftUI / IOKit / XPC。我（前一個 session 的 Claude）已協助使用者從零開始開發到目前可運作版本。

- **專案路徑**：`~/Developer/MacSentinel/`
- **Xcode 專案**：`MacSentinel.xcodeproj`（由 xcodegen 從 `project.yml` 產生）
- **GUI 版本**：1.0.0（macOS 14.0 Sonoma+，Universal Binary arm64 + x86_64）
- **安裝檔**：`~/Developer/MacSentinel/dist/MacSentinel-1.0.0.dmg`（3.9 MB）
- **規模**：10,111 lines of Swift/ObjC、25 個單元測試、14 個 MCP 工具

## 技術堆疊（含本 session 的決定）

| 層 | 選擇 |
|---|---|
| 語言 | Swift 5.10 + Objective-C (bridging for SMC / IOKit) |
| UI | SwiftUI + Swift Charts + AppKit (NSStatusItem) |
| 系統 API | IOKit, SMC, IOHIDEventSystem (private), Mach (host_processor_info / vm_statistics64 / proc_pidinfo), Security framework (SecStaticCode*) |
| 並行 | Swift Concurrency (`@Observable`, actors) + GCD for performance hotpaths |
| 部署目標 | macOS 14.0+（不再 Sandbox，Notarized Direct Distribution） |
| 專案產生 | xcodegen 2.45.4（**永遠改 `project.yml` 不直接改 .xcodeproj**） |
| IPC | NSXPCConnection + SMAppService daemon manifest |
| AI 整合 | MCP server (JSON-RPC 2.0 over stdio)，非 API 呼叫 |

## 三個編譯目標

| Target | 用途 |
|---|---|
| `MacSentinel` | 主 GUI App（裝到 /Applications/）|
| `MacSentinelMCP` | CLI binary，提供 14 個 MCP 工具給 Claude Desktop / Cursor 等本機 AI 助理（嵌在 `.app/Contents/MacOS/macsentinel-mcp`）|
| `MacSentinelHelper` | Privileged XPC Helper，跑為 root daemon 處理 `/Library/LaunchAgents/` 等系統路徑（透過 SMAppService 註冊）|

## 重要檔案結構

```
~/Developer/MacSentinel/
├── project.yml                                # xcodegen spec — 唯一專案來源
├── HANDOFF.md                                  # ← 你正在讀的這份
├── dist/MacSentinel-1.0.0.dmg                 # 最新安裝檔
├── Scripts/
│   ├── build_dmg.sh                           # 一鍵 Release build + DMG 打包
│   ├── GenerateAppIcon.swift                  # CoreGraphics 程式化生成 icon
│   ├── cleanup_full.sh                        # 過去 session 用過的清理腳本（保留）
│   └── cleanup_remaining_16.sh                # 同上
├── MacSentinel/
│   ├── App/
│   │   ├── MacSentinelApp.swift               # @main + 環境注入
│   │   ├── AppDelegate.swift                  # NSStatusItem menu bar
│   │   ├── Info.plist                         # LSMinimumSystemVersion 14.0
│   │   └── MacSentinel.entitlements           # 非 sandbox + cs.disable-library-validation
│   ├── Bridge/                                # C/ObjC bridges
│   │   ├── SMCBridge.h/.m                     # SMC fan/power (Intel 用 + Apple Silicon fallback)
│   │   ├── IOKitBridge.h/.m                   # AppleSmartBattery + Disk I/O
│   │   ├── ThermalSensorBridge.h/.m           # IOHIDEventSystem (Apple Silicon CPU 溫度)
│   │   └── MacSentinel-Bridging-Header.h
│   ├── Models/
│   │   ├── SystemSnapshot.swift               # CPU/Memory/Battery/Disk/Network/Thermal structs
│   │   ├── ProcessTrust.swift                 # 5-level trust enum + ProcessTrustInfo
│   │   ├── SafetyLevel.swift                  # safe/recommended/caution/risky (NO SwiftUI)
│   │   ├── AppleSystemServices.swift          # 60+ Apple daemon allowlist + macl Group Container prefixes
│   │   ├── BrowserScan.swift                  # 8 瀏覽器擴充模型
│   │   └── NetworkScan.swift                  # /etc/hosts / DNS / PAC / LaunchDaemons 異常
│   ├── Services/
│   │   ├── FileSystem/
│   │   │   ├── CacheScanner.swift             # 6 大類快取掃描（已去重 + 過濾 < 1KB）
│   │   │   ├── AppResidualScanner.swift       # /Applications/*.app + 22 條殘留路徑
│   │   │   ├── SafeDeleteService.swift        # 4 段 fallback (direct → Finder → XPC → 報告)
│   │   │   └── TrashService.swift             # 一鍵清空垃圾桶 (osascript Finder)
│   │   ├── Migration/MigrationScanner.swift   # Rosetta apps / 孤兒 LaunchAgents / Containers / kexts
│   │   │                                        # (已加 Apple 系統服務白名單 + bundle ID 前綴匹配)
│   │   ├── Process/
│   │   │   ├── ProcessSnapshot.swift          # proc_pidinfo 行程列表 + CPU delta
│   │   │   └── ProcessTrustService.swift      # SecStaticCode* 簽章驗證 (5 級 + Apple Root fallback)
│   │   ├── Security/
│   │   │   ├── BrowserScanner.swift           # Chromium/Firefox/Safari 擴充 + 風險分數
│   │   │   ├── NetworkScanner.swift           # hosts/DNS/PAC/LaunchDaemons
│   │   │   ├── XProtectReader.swift           # 讀 /Library/Apple/.../XProtect.bundle yara 規則
│   │   │   ├── PermissionService.swift        # FDA 偵測 + macl xattr 偵測
│   │   │   └── PrivilegedHelperConnection.swift  # SMAppService client
│   │   ├── SystemData/SystemDataCollector.swift  # Dashboard 主資料源（2s 採樣）
│   │   ├── AI/AIScanReporter.swift            # 掃描結果 → JSON for AI consumption
│   │   └── ScanHistoryService.swift           # Before/After delta（JSONL 存於 App Support）
│   ├── Utilities/
│   │   ├── ProtectedPaths.swift               # 反向設計 — 短列表的明確保護路徑
│   │   ├── AuditLog.swift                     # JSON Lines audit log (~/Library/App Support/.../audit.jsonl)
│   │   ├── ByteFormatter.swift
│   │   └── MCPConfig.swift                    # mcp-config.json (allowRealDelete, enabled)
│   ├── Shared/HelperProtocol.swift            # 兩個 target 共用的 XPC 協定
│   ├── Views/
│   │   ├── Main/{ContentView,SidebarView}.swift  # NavigationSplitView + 8 sidebar items
│   │   ├── Dashboard/DashboardView.swift      # 含 FDA Permission Banner
│   │   ├── Cleaner/CacheCleanerView.swift     # checkbox + safety badge + 清空垃圾桶
│   │   ├── Uninstaller/AppUninstallerView.swift  # Set<UUID> 選取（修過效能 bug）
│   │   ├── Processes/ProcessListView.swift    # 含 ProcessTrustDetailSheet 信任度詳細面板
│   │   ├── Migration/MigrationScanView.swift  # 含 kext 重開機 alert
│   │   ├── Security/BrowserScanView.swift
│   │   ├── Security/NetworkScanView.swift
│   │   ├── Components/SafetyBadge.swift       # SwiftUI 部分（從 SafetyLevel.swift 拆出）
│   │   ├── Settings/SettingsView.swift        # MCP 設定 + 開源致謝 sheet
│   │   └── MenuBar/MenuBarPopoverView.swift
│   └── Resources/
│       ├── Assets.xcassets/AppIcon.appiconset/  # 7 個尺寸 PNG（六角盾形 + 脈衝線）
│       └── LaunchDaemons/com.macsentinel.helper.plist  # SMAppService manifest
├── MacSentinelMCP/                            # CLI MCP server
│   ├── main.swift                              # RunLoop.main.run() + 14 tool register
│   ├── MCPProtocol.swift                       # JSON-RPC 2.0 + JSONValue
│   ├── MCPServer.swift                         # 含 DeletionFailureClassifier (TCC/sudo/macl/protected)
│   └── Tools/
│       ├── ScanTools.swift                     # 5 個掃描工具 (caches/apps/migration/capabilities/xprotect 補位)
│       ├── ProcessTools.swift                  # list_processes
│       ├── SecurityTools.swift                 # scan_process_trust, scan_browsers, scan_network, scan_xprotect, get_system_health, kill_process, set_dry_run
│       └── DeleteTools.swift                   # trash_items (含失敗分類 + suggestion), read_audit_log
├── MacSentinelHelper/                          # 特權 daemon
│   ├── main.swift                              # NSXPCListener + 簽章驗證 (kSecGuestAttributeAudit)
│   └── Info.plist
└── MacSentinelTests/                           # 25 個單元測試
    ├── ByteFormatterTests.swift
    ├── ProtectedPathsTests.swift               # 14 個 case
    ├── AppleSystemServicesTests.swift          # 5 個
    └── ProcessTrustServiceTests.swift          # 3 個 (XProtect, remotepairingd, launchctl 整合測試)
```

## 14 個 MCP 工具（已運作中）

| 工具 | 唯讀/寫入 |
|---|---|
| `macsentinel.list_capabilities` | 唯讀 |
| `macsentinel.scan_caches` | 唯讀（6 大類 + 去重 + 過濾雜訊）|
| `macsentinel.scan_apps` | 唯讀（支援 `limit`/`summary_only`/`filter_arch`）|
| `macsentinel.scan_migration` | 唯讀（含 Apple 系統服務白名單 + 前綴匹配）|
| `macsentinel.list_processes` | 唯讀 |
| `macsentinel.scan_process_trust` | 唯讀（5 級分類 + Apple Root fallback）|
| `macsentinel.scan_browsers` | 唯讀（8 個瀏覽器擴充 + 風險分數）|
| `macsentinel.scan_network` | 唯讀（hosts/DNS/PAC/LaunchDaemons）|
| `macsentinel.scan_xprotect` | 唯讀（203 條 Apple yara 規則）|
| `macsentinel.get_system_health` | 唯讀（CPU/Mem/Disk/Battery/Thermal 即時）|
| `macsentinel.read_audit_log` | 唯讀（JSON Lines）|
| `macsentinel.trash_items` | **寫入**（dry-run 預設、失敗附 suggestion 分類）|
| `macsentinel.kill_process` | **寫入**（L5 自動拒絕）|
| `macsentinel.set_dry_run` | **寫入**（持久化到 mcp-config.json）|

## 整合到 Claude Desktop

設定在 `~/Library/Application Support/Claude/claude_desktop_config.json`：
```json
{
  "mcpServers": {
    "macsentinel": {
      "command": "/Applications/MacSentinel.app/Contents/MacOS/macsentinel-mcp",
      "args": []
    }
  }
}
```

## 本 session 完成的 44 個任務（按主題）

### 修復與優化（從實機清理踩到的 bug）
1. App 移除勾選效能 Bug（Set<UUID> 取代 struct 重複複製）
2. 遷移掃描誤判 com.apple.* 為孤兒 → AppleSystemServices 白名單
3. 子助手 bundle ID 被誤判 → MigrationScanner 前綴匹配
4. CacheScanner 同路徑雙重計算 → 跨分類去重
5. ProtectedPaths blanket-protect ~/Library 反向設計
6. Xcode DerivedData 被 ProtectedPaths 誤擋
7. LaunchAgents 被 ProtectedPaths 誤擋
8. ProcessTrust 把 /Library/Apple/* 的 Apple 服務誤判為 Ad-hoc
9. Audit log 改為 JSON Lines 格式

### 新增的核心功能
10. **5 大模組**: System Monitor / Process Manager / Cache Cleaner / App Uninstaller / Migration Scanner（從零）
11. **Apple Silicon 溫度感測**：IOHIDEventSystemClient 私有 API（取代失效的 SMC TCxx keys）
12. **正確的電池健康度**：AppleRawMaxCapacity vs DesignCapacity（解決 2.2% 顯示 bug）
13. **ProcessTrustService**：5 級簽章信任度 + 高風險 entitlements + macl 偵測
14. **BrowserScanner**：Chromium/Firefox/Safari 8 個瀏覽器擴充風險評分 + 內建黑名單
15. **NetworkScanner**：/etc/hosts 敏感網域 + DNS / PAC / 透明代理偵測
16. **XProtectReader**：讀 macOS 內建 yara 規則（203 條）
17. **MCP Server**：14 個工具，JSON-RPC 2.0 over stdio
18. **Privileged XPC Helper**：SMAppService daemon + 客戶端簽章驗證
19. **PermissionService**：FDA 自動偵測 + Dashboard banner 引導
20. **多層 SafeDeleteService**：4 段 fallback (direct → Finder ACL → XPC Helper → 報告)
21. **AI 整合架構轉變**：從「呼叫雲端 API」改為「成為 MCP Server」

### UX 改進
22. macOS Big Sur+ 六角盾 + 脈衝線 AppIcon（CoreGraphics 程式化生成）
23. DashboardView FDA Permission Banner
24. CacheCleanerView 清空垃圾桶按鈕
25. MigrationScanView kext 移除後重開機 alert
26. ScanHistoryService（Before/After delta — JSONL 持久化）
27. Settings: 開源致謝 + MCP 連線設定指引 + 「AI 助理整合」區塊
28. 錯誤訊息分級（tccBlocked / rootRequired / maclACL / protectedByPolicy）每個附 suggestion
29. Process Trust Detail Sheet（簽章 / 憑證鏈 / entitlements）

### 工程品質
30. xcodegen project.yml 完全 idempotent
31. `build_dmg.sh` 一鍵 Release + 簽章 + DMG
32. 25 個單元測試（ByteFormatter 3 / ProtectedPaths 14 / AppleSystemServices 5 / ProcessTrustService 3）
33. Audit log 自動 trim（max 1000 entries）

## 實機清理戰績（這 session 用本程式真實清的）

| 項目 | 數量 |
|---|---|
| 釋放磁碟空間 | **~14 GB** |
| 移除可疑 LaunchAgents | 8 個（含 **minergate 挖礦軟體**）|
| 移除 legacy kexts | 4 個（SoftRAID, HighPoint x2, HP）|
| 移除 Intel-only Apps | 5 個（xTool, OBS, BLIePKIAgentson, LadioCast, SyphonInject）|
| 移除孤兒 Containers | 50+ 個（WeChat / Office / LINE / Telegram / Adobe / 趨勢科技 / HP / NordVPN / ...）|
| 清除 openclaw 完整殘留 | 554 MB npm 套件 + LaunchAgent + ~/.openclaw + .bash_profile 修復 |
| 修復終端機啟動錯誤 | bash 第 10 行的 source 不存在的 openclaw.bash |

## 已知限制 / 仍未實作

| 項目 | 狀態 |
|---|---|
| Privileged XPC Helper 實際 SMAppService 註冊流程 | ⚠️ 程式碼完整但 **未實際在使用者機器上 register()** — 需 UI 流程引導使用者觸發 |
| Browser 擴充黑名單動態更新 | ⚠️ 目前只有 4 條 hardcoded IOC（Awake Security 2020）— 待接 CRXcavator API / Mozilla blocklist feed |
| AI Provider 真實 API 呼叫 | ❌ AIVerifier.swift 已刪除（改走 MCP）。如果未來要回頭做雲端 verify，git log 找回 |
| Process Trust 性能 | ⚠️ scan_process_trust 限 100 個會 timeout — `SecStaticCodeCheckValidity` 比預期慢，需 cache 預熱或減少 entitlement 解析 |
| Logs trash | ⚠️ ~/Library/Logs 整個目錄無法 trash（TCC + macOS 持續寫入）— 只能刪內含的舊檔 |
| Apple Silicon GPU 溫度 | ⚠️ IOHIDEventSystem 只暴露 CPU 溫度，GPU 還是顯示「—」 |
| kext 真正卸載 | ⚠️ rm -rf 後仍在 kernel cache，必須重開機（已有 alert 提醒）|

## 重要的設計決策（不要輕易推翻）

1. **ProtectedPaths 反向設計**：保護短清單而非 blanket-protect。舊版有過反例（DerivedData/LaunchAgents 被誤擋）。
2. **trash 走 4 段 fallback**：direct → osascript Finder → XPC Helper → 報告。原因：TCC / com.apple.macl ACL / sudo 三種不同障礙各需不同解法。
3. **Apple Root + Apple Software Signing 雙重判定 = L5**：避免將來 Apple 把系統服務搬到新路徑時又要改 isAppleSystemPath。
4. **MCP server 非 daemon**：每次 Claude Desktop 啟動會 spawn 新 process，無常駐風險。
5. **JSON Lines audit log**：方便 AI 解析 + tail-friendly。
6. **xcodegen 是唯一專案來源**：絕對不要直接編輯 .xcodeproj。
7. **HelperProtocol.swift 位於 `MacSentinel/Shared/`**：兩個 target 同檔同源，編譯到各自 module。

## Build / Test / Release

```bash
# 重新產生 Xcode 專案
cd ~/Developer/MacSentinel && xcodegen generate

# Debug 編譯主 App
xcodebuild -project MacSentinel.xcodeproj -scheme MacSentinel -configuration Debug build

# 跑所有測試
xcodebuild test -project MacSentinel.xcodeproj -scheme MacSentinel -destination 'platform=macOS'

# 編 Release 並打包 DMG
./Scripts/build_dmg.sh
# → 產出 dist/MacSentinel-1.0.0.dmg

# Hot-swap 已安裝的 MCP binary（測試新版本不需重新 install）
cp build/hotpatch/Build/Products/Release/macsentinel-mcp \
   /Applications/MacSentinel.app/Contents/MacOS/macsentinel-mcp
codesign --force --sign - /Applications/MacSentinel.app/Contents/MacOS/macsentinel-mcp
# 然後重啟 Claude Desktop 即可使用新版
```

## 接下來可以做的事（按優先序排）

### 🔴 P0 — 真正完成 Privileged Helper
- `PrivilegedHelperConnection.install()` 在 SettingsView 加 UI 按鈕觸發
- 處理 SMAppService 第一次 register 後的 "requiresApproval" 狀態
- 第一次需要清 /Library/LaunchAgents 時自動引導使用者去 Login Items 啟用 helper
- 寫個整合測試（部分 mock SMAppService）

### 🔴 P0 — 修 scan_process_trust 性能
- 預先 SecStaticCode cache（背景 task 慢慢 warm up）
- 用 `task_for_pid` 取 SecCode for running process（更快，但需 entitlement）
- 或：只在使用者按「行程管理」頁時才 batch-evaluate 可見的 100 個（lazy + concurrent）

### 🟠 P1 — Browser 擴充黑名單動態更新
- 寫 `BrowserBlocklistFeed.swift` 拉 Mozilla blocked-list、CRXcavator API
- 每天背景更新 + 快取 24h
- 在 SettingsView 加「黑名單上次更新」資訊

### 🟠 P1 — Bundle App 自動移除全部殘留
- 目前 AppUninstaller 仍會被 `com.apple.macl` 擋
- 自動偵測 macl → 走 osascript Finder（已有邏輯，但要在 GUI 也接上）
- 加 Application Scripts 殘留偵測（本 session 已知盲點）

### 🟡 P2 — 整合 LLM 通過 MCP 雙向
- 目前 MacSentinel 作為 MCP server 等別人來呼叫
- 反向：在 MacSentinel UI 內讓使用者直接「問 AI」（透過內建 chat 介面接 Claude API 或 Ollama）

### 🟡 P2 — Browser Profile-Aware
- 目前 Chrome 整包 `~/Library/Caches/Google/` 統一報
- 拆 per-profile（Default / Profile 1 / Profile 5）讓使用者選擇清哪個

### 🟢 P3 — 更多 MCP 工具
- `scan_login_items`（macOS 13+ Login Items API）
- `analyze_hosts_diff`（與 Steven Black hosts 對比）
- `kext_history`（讀 kextcache 歷史）

## 一句話總結

**目前狀態**：可立即發布的 1.0.0，44 個任務全做完，25 個測試通過，DMG 已備好。最重要的 P0 工作是讓 Privileged Helper 真正進入使用者的 Login Items 流程 — 程式碼已寫好 80%，差最後的 UI 引導。

---

## 你接手時請先做這 3 件事

1. `cd ~/Developer/MacSentinel && xcodegen generate && xcodebuild test` 驗證測試全綠
2. 開 `project.yml` 看現在的 3 個 target + 共用源碼配置
3. 開 `HANDOFF.md` (這個檔案) 對照新需求

如果使用者沒有特別說要做什麼，**直接問**：
> 「目前要朝 P0 / P1 / P2 / P3 哪個方向繼續？或是要修我沒注意到的 bug？」

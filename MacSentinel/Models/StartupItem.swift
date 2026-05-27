//
//  StartupItem.swift
//  MacSentinel
//
//  Model + knowledge base for LaunchAgents / LaunchDaemons. The knowledge
//  base contains 40+ heuristics ported from MacCleanerPro that label each
//  startup item as "建議開啟 / 建議關閉 / 依需求" with a Chinese rationale.
//
//  Pure-model file (no SwiftUI / AppKit). Shared by GUI + MCP CLI.
//

import Foundation

// MARK: - Recommendation enum

enum StartupRecommendation: String, Codable {
    case shouldEnable   = "建議開啟"
    case shouldDisable  = "建議關閉"
    case neutral        = "依需求決定"

    var systemImage: String {
        switch self {
        case .shouldEnable:  return "checkmark.shield.fill"
        case .shouldDisable: return "bolt.slash.fill"
        case .neutral:       return "questionmark.circle"
        }
    }
}

// MARK: - Item model

struct StartupItem: Identifiable, Hashable {
    let id = UUID()
    let label: String           // plist Label
    let name: String            // user-facing name (filename without .plist)
    let path: String            // absolute path to the .plist
    let program: String         // executable path (from Program or ProgramArguments[0])
    var isEnabled: Bool         // current Disabled=false state
    let isSystemLevel: Bool     // true if under /Library, requires admin to toggle

    var recommendation: StartupRecommendation = .neutral
    var descriptionText: String = "背景服務，若不確定其用途，建議保持目前狀態。"

    var sourceDescription: String {
        if path.contains("/Library/LaunchDaemons") { return "系統背景服務（root daemon）" }
        if path.contains("/Library/LaunchAgents")  { return "系統登入項目（所有使用者）" }
        return "使用者登入項目"
    }

    func hash(into hasher: inout Hasher) { hasher.combine(label); hasher.combine(path) }
    static func == (lhs: StartupItem, rhs: StartupItem) -> Bool {
        lhs.label == rhs.label && lhs.path == rhs.path
    }
}

// MARK: - Knowledge base

enum StartupKnowledgeBase {

    /// Match by keyword (case-insensitive) against label / name / program.
    /// First matching rule wins.
    static let rules: [(keyword: String, recommendation: StartupRecommendation, description: String)] = [
        // ── 防毒 / 安全（建議開啟）───────────────────────────────────
        ("malwarebytes",     .shouldEnable,  "Malwarebytes 防毒軟體核心常駐程式，關閉將影響即時偵測。"),
        ("norton",           .shouldEnable,  "Norton 安全軟體常駐程式，關閉將停止即時防護。"),
        ("sophos",           .shouldEnable,  "Sophos 企業級防毒軟體，關閉將影響安全防護。"),
        ("kaspersky",        .shouldEnable,  "Kaspersky 防毒軟體常駐程序，建議保持開啟。"),
        ("crowdstrike",      .shouldEnable,  "CrowdStrike 企業端點安全防護程式，請勿關閉。"),
        ("sentinelone",      .shouldEnable,  "SentinelOne 企業端點安全防護，請勿關閉。"),
        ("xprotect",         .shouldEnable,  "Apple 內建惡意軟體防護機制（XProtect），請勿關閉。"),
        ("gatekeeper",       .shouldEnable,  "Apple 內建簽章驗證閘道（Gatekeeper），請勿關閉。"),
        ("littlesnitch",     .shouldEnable,  "Little Snitch 網路防火牆，關閉將無法監控外連。"),
        ("lulu",             .shouldEnable,  "Objective-See LuLu 開源網路防火牆，建議保持開啟。"),

        // ── 備份 / 同步（多數建議開啟）─────────────────────────────
        ("timemachine",      .shouldEnable,  "Apple Time Machine 備份服務，建議保持開啟以確保自動備份。"),
        ("backblaze",        .shouldEnable,  "Backblaze 雲端備份服務，關閉將停止自動備份。"),
        ("carbonite",        .shouldEnable,  "Carbonite 雲端備份常駐程式，建議保持開啟。"),
        ("arq",              .shouldEnable,  "Arq Backup 雲端備份服務，建議保持開啟。"),
        ("icloud",           .shouldEnable,  "Apple iCloud 同步服務，關閉將停止同步照片、文件、Drive 等資料。"),

        // ── 雲端同步（依需求）─────────────────────────────────────
        ("dropbox",          .neutral,       "Dropbox 雲端同步服務，若不使用 Dropbox 可關閉以節省記憶體與電力。"),
        ("googledrive",      .neutral,       "Google Drive 同步服務，若不使用可關閉。"),
        ("onedrive",         .neutral,       "Microsoft OneDrive 同步服務，若不使用可關閉。"),
        ("box",              .neutral,       "Box Sync 同步服務，若不使用可關閉。"),

        // ── 第三方更新器（多數建議關閉）─────────────────────────────
        ("sparkle",          .shouldDisable, "第三方軟體的 Sparkle 更新檢查器，關閉可加快開機速度，需要時手動更新即可。"),
        ("autoupdate",       .shouldDisable, "自動更新檢查服務，關閉後需手動檢查更新，但可加快開機速度。"),
        ("updater",          .shouldDisable, "軟體自動更新檢查器，關閉可加快開機速度。"),
        ("microsoftautoupdate", .shouldDisable, "Microsoft Office 自動更新，可關閉後改手動更新。"),
        ("googleupdater",    .shouldDisable, "Google 軟體自動更新，可關閉後改用瀏覽器內建更新。"),
        ("adobegcclient",    .shouldDisable, "Adobe 自動更新與背景服務，可關閉以節省資源。"),
        ("adobegcclient.agent", .shouldDisable, "Adobe Genuine Software Service，可關閉。"),
        ("creative cloud",   .shouldDisable, "Adobe Creative Cloud 常駐，需要時手動啟動即可。"),

        // ── Apple 系統服務（一律建議保留）───────────────────────────
        ("com.apple.",       .shouldEnable,  "Apple 系統內建服務，建議保持開啟以維持系統正常運作。"),

        // ── 通訊軟體（依需求）────────────────────────────────────
        ("telegram",         .neutral,       "Telegram 訊息應用常駐程式，關閉後需手動啟動才會收到通知。"),
        ("slack",            .neutral,       "Slack 團隊通訊常駐程式，若不需即時通知可關閉。"),
        ("discord",          .neutral,       "Discord 通訊常駐程式，關閉後需手動啟動。"),
        ("zoom",             .shouldDisable, "Zoom 視訊助手常駐程式，關閉可加快開機，視訊會議時啟動 Zoom 即可。"),
        ("teams",            .neutral,       "Microsoft Teams 常駐程式，若不需即時通知可關閉。"),
        ("wechat",           .neutral,       "微信常駐程式，關閉後需手動啟動才會收到通知。"),
        ("line",             .neutral,       "LINE 通訊常駐程式，關閉後需手動啟動。"),
        ("whatsapp",         .neutral,       "WhatsApp 桌面版常駐程式，依需求決定。"),

        // ── 系統效能 / 選單列工具（依需求）───────────────────────────
        ("cleanmymac",       .shouldDisable, "CleanMyMac 常駐監控，關閉不影響手動清理功能。"),
        ("bartender",        .neutral,       "Bartender 選單列管理工具，關閉將恢復預設選單列顯示。"),
        ("alfred",           .neutral,       "Alfred 啟動器常駐程式，關閉後無法使用快捷鍵搜尋。"),
        ("raycast",          .neutral,       "Raycast 啟動器常駐程式，關閉後無法使用快捷鍵搜尋。"),
        ("karabiner",        .shouldEnable,  "Karabiner-Elements 鍵盤自訂工具，關閉後自訂按鍵映射將失效。"),
        ("iterm2",           .neutral,       "iTerm2 系統服務，關閉不影響主程式運作。"),
        ("rectangle",        .neutral,       "Rectangle 視窗管理工具，關閉後快捷鍵將無效。"),
        ("magnet",           .neutral,       "Magnet 視窗管理工具，關閉後快捷鍵將無效。"),

        // ── 開發者工具 / 資料庫（依需求）─────────────────────────────
        ("docker",           .neutral,       "Docker Desktop 常駐程式，不使用容器時可關閉以節省記憶體（約 1-2 GB）。"),
        ("colima",           .neutral,       "Colima 容器執行環境，不使用時可關閉。"),
        ("postgres",         .neutral,       "PostgreSQL 資料庫服務，未使用時可關閉。"),
        ("mysql",            .neutral,       "MySQL 資料庫服務，未使用時可關閉。"),
        ("mongodb",          .neutral,       "MongoDB 資料庫服務，未進行開發時可關閉。"),
        ("redis",            .neutral,       "Redis 快取服務，未進行開發時可關閉。"),
        ("nginx",            .neutral,       "Nginx 網頁伺服器，未使用時可關閉。"),
        ("httpd",            .neutral,       "Apache HTTP 伺服器，未使用時可關閉。"),

        // ── VPN（依需求，但通常想保留）──────────────────────────────
        ("nordvpn",          .neutral,       "NordVPN 客戶端常駐，需自動連線時保留，否則可關閉。"),
        ("expressvpn",       .neutral,       "ExpressVPN 客戶端常駐，需自動連線時保留。"),
        ("surfshark",        .neutral,       "Surfshark VPN 客戶端常駐，需自動連線時保留。"),
        ("tailscale",        .neutral,       "Tailscale mesh VPN daemon，跨裝置連線需要保留。"),
    ]

    static func evaluate(_ item: inout StartupItem) {
        let l = item.label.lowercased()
        let n = item.name.lowercased()
        let p = item.program.lowercased()
        for rule in rules {
            if l.contains(rule.keyword) || n.contains(rule.keyword) || p.contains(rule.keyword) {
                item.recommendation = rule.recommendation
                item.descriptionText = rule.description
                return
            }
        }
        // Fallback
        if item.isSystemLevel {
            item.recommendation = .neutral
            item.descriptionText = "系統層級背景服務，若不確定其用途，建議保持目前狀態。"
        } else {
            item.recommendation = .neutral
            item.descriptionText = "第三方背景服務，若不常使用該軟體可考慮關閉以加快開機速度。"
        }
    }
}

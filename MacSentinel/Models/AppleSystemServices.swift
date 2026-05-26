import Foundation

/// 已知的 macOS 系統服務 bundle ID 清單。
/// 這些服務沒有 GUI App（用 NSWorkspace 找不到對應 .app），但屬作業系統必備
/// daemon / agent / system service。掃描器若把它們報為「孤兒」會導致使用者
/// 誤刪而破壞照片庫索引、定位服務、Spotlight 等核心功能。
///
/// 來源：實機掃描 + Apple 官方文件 + 對照 /System/Library/LaunchAgents/* 與
/// /System/Library/LaunchDaemons/* 的 plist 內容。
enum AppleSystemServices {

    /// 已知的系統 daemon / agent / extension。對應 ~/Library/Containers/<id>
    /// 與 ~/Library/Group Containers/<id> 內的同名項目應自動排除為「系統必備」。
    static let knownDaemons: Set<String> = [
        // 媒體與相片
        "com.apple.mediaanalysisd",
        "com.apple.photoanalysisd",
        "com.apple.photolibraryd",
        "com.apple.AMPArtworkAgent",         // Apple Music / Podcasts 封面
        "com.apple.AMPLibraryAgent",
        "com.apple.mediastream.mstreamd",
        "com.apple.cloudphotod",
        "com.apple.SocialPhotosAgent",
        "com.apple.assetsd",

        // 定位與地圖
        "com.apple.geod",                    // 地理位置 + Significant Locations
        "com.apple.routined",                // 常用地點學習
        "com.apple.locationd",
        "com.apple.maps.mapspushd",

        // 聲音與輸入
        "com.apple.voicebankingd",
        "com.apple.inputmethod.TCIM",
        "com.apple.inputmethod.SCIM",
        "com.apple.inputmethod.Kotoeri",
        "com.apple.inputmethod.Korean",

        // 桌面 / Avatar / 螢幕
        "com.apple.wallpaper.agent",
        "com.apple.AvatarUI.AvatarPickerMemojiPicker",
        "com.apple.ScreenSaver.Engine.legacyScreenSaver",
        "com.apple.ScreenContinuity",

        // 系統 widget / extension
        "com.apple.stocks.widget",
        "com.apple.weather.widget",
        "com.apple.podcasts.widget",
        "com.apple.iCal.CalendarWidgetExtension",
        "com.apple.findmy.findmydeviceswidget",
        "com.apple.reminders.widget",

        // 系統設定 / 帳號
        "com.apple.systempreferences.AppleIDSettings",
        "com.apple.ScreenTimeAgent",
        "com.apple.StorageManagement.CloudStorageHelper",
        "com.apple.CalendarAgent",
        "com.apple.notificationcenterui.widget",

        // iCloud / Cloud Documents
        "com.apple.CloudDocs.iCloudDriveFileProvider",
        "com.apple.bird",                    // CloudKit
        "com.apple.cloudd",

        // Spotlight / Help / 系統 cache
        "com.apple.parsecd",
        "com.apple.helpd",
        "com.apple.suggestd",
        "com.apple.knowledge-agent",

        // Apple silicon 專屬
        "com.apple.WindowManager",
        "com.apple.appleseed.feedbackd",
    ]

    /// Apple 自家的 Group Container ID 前綴。這些屬系統共享資料，永不視為孤兒。
    /// （Apple 開發者 Team ID 多以 10 字元字母數字組合表示）
    static let knownAppleGroupPrefixes: Set<String> = [
        "74J34U3R6X",              // Apple iWork suite
        "243LU875E5",              // Apple Podcasts
        "9PSP3CDPV2",              // Apple developer tools
        "10VG37BCSC",              // Apple various
        "JWKAR26T28",              // Apple developer / debug
        "K36BKF7T3D",              // Apple TestFlight
    ]

    /// macOS Shortcuts / Workflows 的特殊 group 命名。
    static let knownWorkflowGroups: Set<String> = [
        "group.is.workflow.my.app",
        "group.is.workflow.shortcuts",
        "group.com.apple.AppleSpell",
    ]

    /// 判斷某個 bundle ID（或 group container ID）是否屬於 Apple 系統服務 —
    /// 一律不該被列為孤兒。
    static func isAppleSystemService(_ bundleID: String) -> Bool {
        // 1. 直接命中清單
        if knownDaemons.contains(bundleID) { return true }
        if knownWorkflowGroups.contains(bundleID) { return true }

        // 2. Apple 系統 prefix
        if bundleID.hasPrefix("com.apple.") { return true }

        // 3. Apple Group Container 前綴比對（如 74J34U3R6X.com.apple.iWork）
        for prefix in knownAppleGroupPrefixes {
            if bundleID.hasPrefix(prefix + ".") { return true }
        }

        return false
    }

    /// 對應於 Container ID 的人類可讀說明 — UI 用來告訴使用者「為什麼不能刪」。
    static func humanDescription(for bundleID: String) -> String? {
        let descriptions: [String: String] = [
            "com.apple.mediaanalysisd": "照片自動分類 / 人臉識別 / 場景標記服務（刪除會導致相片庫重建索引，可能耗時數小時）",
            "com.apple.photoanalysisd": "照片場景分析服務（同上）",
            "com.apple.photolibraryd": "照片庫資料服務（系統相片 App 必備）",
            "com.apple.AMPArtworkAgent": "Apple Music / Podcasts 封面快取代理",
            "com.apple.geod": "地理位置 / 常用地點 / 「尋找」服務",
            "com.apple.routined": "「常用地點」學習資料（地圖建議用）",
            "com.apple.locationd": "macOS 定位服務核心",
            "com.apple.voicebankingd": "個人聲音（Voice Banking）",
            "com.apple.parsecd": "Spotlight 智慧搜尋索引",
            "com.apple.helpd": "macOS Help 系統索引",
            "com.apple.wallpaper.agent": "動態桌布服務",
            "com.apple.AvatarUI.AvatarPickerMemojiPicker": "Memoji 編輯器",
            "com.apple.CloudDocs.iCloudDriveFileProvider": "iCloud Drive 同步服務",
            "com.apple.ScreenTimeAgent": "螢幕使用時間",
            "com.apple.CalendarAgent": "行事曆同步服務",
        ]
        if let desc = descriptions[bundleID] { return desc }
        if bundleID.hasPrefix("com.apple.") {
            return "Apple 系統服務（無 GUI App，不建議刪除）"
        }
        return nil
    }
}

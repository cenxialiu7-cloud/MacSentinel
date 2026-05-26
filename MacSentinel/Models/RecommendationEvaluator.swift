//
//  RecommendationEvaluator.swift
//  MacSentinel
//
//  Per-item recommendation engine. Given a file's path, modification date and
//  size, produces:
//    • a SafetyLevel  — same scale as the existing badges
//    • a recommendedAction — should the user delete this?
//    • a reasonText — one-sentence rationale in 繁體中文 ("為什麼是這級")
//
//  Adapted from MacCleanerPro's RecommendationEngine.evaluate(...). Pure
//  logic — no SwiftUI imports — so it's shared by the GUI app and the MCP
//  CLI target.
//

import Foundation

/// Suggested action on a single scanned item.
enum RecommendedAction: String, Codable {
    case delete     // safe / beneficial to remove
    case caution    // can delete but read the reason first
    case keep       // do not delete

    var label: String {
        switch self {
        case .delete:  return "建議刪除"
        case .caution: return "請評估"
        case .keep:    return "建議保留"
        }
    }

    var systemImage: String {
        switch self {
        case .delete:  return "trash.circle.fill"
        case .caution: return "exclamationmark.circle.fill"
        case .keep:    return "checkmark.shield.fill"
        }
    }
}

/// Complete evaluation result for one scanned item.
struct ItemRecommendation: Codable, Hashable {
    let safetyLevel: SafetyLevel
    let action: RecommendedAction
    let reasonText: String

    /// Stable JSON-friendly representation for MCP responses.
    var jsonDictionary: [String: String] {
        [
            "safety": safetyLevel.jsonKey,
            "action": action.rawValue,
            "reason": reasonText
        ]
    }
}

enum RecommendationEvaluator {

    /// Evaluate a scanned item. All inputs are optional / lenient — missing
    /// metadata just yields more conservative recommendations.
    static func evaluate(
        path: String,
        modificationDate: Date? = nil,
        sizeBytes: UInt64 = 0,
        isDeletable: Bool = true
    ) -> ItemRecommendation {

        // ─── Rule 0: 無刪除權限 → 直接保留 ───
        if !isDeletable {
            return .init(
                safetyLevel: .caution,
                action: .keep,
                reasonText: "目前沒有刪除這個檔案的權限。請在「系統設定 → 隱私權與安全性 → 完整磁碟取用權」開啟 MacSentinel，或手動刪除。"
            )
        }

        let pathLower = path.lowercased()
        let nameLower = (path as NSString).lastPathComponent.lowercased()
        let daysSinceModified: Int = {
            guard let mod = modificationDate else { return 999 }
            return Calendar.current.dateComponents([.day], from: mod, to: Date()).day ?? 999
        }()
        let baseLevel = SafetyClassifier.classify(path: path)

        // ─── Rule 1: 系統路徑（高風險）─────────────────────────────
        if baseLevel == .risky {
            return .init(
                safetyLevel: .risky,
                action: .keep,
                reasonText: "這個路徑屬於 macOS 系統元件或核心擴充。除非你清楚知道後果，否則請保留。"
            )
        }

        // ─── Rule 2: 最近 3 天內修改過 → 建議保留 ────────────────────
        if let _ = modificationDate, daysSinceModified <= 3 {
            return .init(
                safetyLevel: .caution,
                action: .keep,
                reasonText: "最近 \(daysSinceModified) 天內仍有修改紀錄，可能正在使用中，建議保留以免影響應用程式運作。"
            )
        }

        // ─── Rule 3: 系統 / Apple 核心 keyword → 建議保留 ─────────────
        let systemKeywords = ["com.apple.", "applesystem", "kernel", "launchd"]
        if systemKeywords.contains(where: { nameLower.contains($0) || pathLower.contains($0) }) {
            return .init(
                safetyLevel: .caution,
                action: .keep,
                reasonText: "此項目疑似屬於 Apple 系統核心元件，雖然可能會占空間，但移除可能影響系統服務。"
            )
        }

        // ─── Rule 4: 垃圾桶內 → 建議刪除 ───────────────────────────
        if pathLower.contains("/.trash/") || pathLower.contains("/.trashes/") {
            return .init(
                safetyLevel: .safe,
                action: .delete,
                reasonText: "已在垃圾桶中，可以安全清空釋放空間。"
            )
        }

        // ─── Rule 5: Caches > 30 天 → 建議刪除 ─────────────────────
        if pathLower.contains("/caches/") && daysSinceModified > 30 {
            return .init(
                safetyLevel: .safe,
                action: .delete,
                reasonText: "已超過 \(daysSinceModified) 天未存取的應用程式快取，刪除不會影響功能（下次需要時應用程式會自動重建）。"
            )
        }

        // ─── Rule 6: Caches 但較新 → 評估 ─────────────────────────
        if pathLower.contains("/caches/") {
            return .init(
                safetyLevel: .recommended,
                action: .caution,
                reasonText: daysSinceModified < 999
                    ? "\(daysSinceModified) 天前曾使用過的快取。可以刪除但下次開啟應用程式時會稍慢一些。"
                    : "應用程式快取。刪除後下次開啟應用程式時會自動重建。"
            )
        }

        // ─── Rule 7: Logs / DiagnosticReports → 建議刪除 ────────────
        if pathLower.contains("/library/logs/")
            || pathLower.contains("/diagnosticreports/")
            || pathLower.contains("/crashreporter/")
            || nameLower.hasSuffix(".log") {
            return .init(
                safetyLevel: .safe,
                action: .delete,
                reasonText: "日誌或當機報告，刪除不影響使用，僅會清除過去的紀錄。"
            )
        }

        // ─── Rule 8: 開發者快取（DerivedData / npm / Gradle / Pods）→ 刪除 ─
        let devCachePatterns = [
            "/library/developer/xcode/deriveddata",
            "/library/developer/coresimulator/caches",
            "/.npm/_cacache",
            "/.gradle/caches",
            "/library/caches/cocoapods",
            "/library/caches/carthage",
            "/.cache/pip"
        ]
        if devCachePatterns.contains(where: { pathLower.contains($0) }) {
            return .init(
                safetyLevel: .safe,
                action: .delete,
                reasonText: "開發者工具快取，刪除後下次 build 會自動重新下載/編譯，常釋出數百 MB 到數 GB。"
            )
        }

        // ─── Rule 9: 大檔（> 100 MB）且超過 180 天 → 建議刪除 ──────────
        if sizeBytes >= 100 * 1024 * 1024 && daysSinceModified > 180 {
            return .init(
                safetyLevel: .recommended,
                action: .delete,
                reasonText: "\(ByteFormatter.format(sizeBytes)) 的大檔案，已超過半年未使用，可考慮清除以釋出空間。"
            )
        }

        // ─── Rule 10: 大檔 (> 100 MB) 但較新 → 評估 ────────────────
        if sizeBytes >= 100 * 1024 * 1024 {
            return .init(
                safetyLevel: .caution,
                action: .caution,
                reasonText: "\(ByteFormatter.format(sizeBytes)) 的大檔案，但近期仍有存取，建議先檢視內容再決定是否刪除。"
            )
        }

        // ─── Rule 11: Preferences / Application Support → 評估 ─────
        if pathLower.contains("/library/preferences/")
            || pathLower.contains("/library/application support/")
            || pathLower.contains("/library/containers/") {
            return .init(
                safetyLevel: .caution,
                action: .caution,
                reasonText: "包含應用程式設定或登入狀態。刪除後該應用程式可能需重新登入或重新設定。"
            )
        }

        // ─── Fallback：依路徑安全等級給出泛用文案 ────────────────
        return .init(
            safetyLevel: baseLevel,
            action: baseLevel == .safe ? .delete : .caution,
            reasonText: baseLevel.rationale
        )
    }

    /// Convenience: evaluate by reading the file's modificationDate from disk.
    /// Slower than the direct version — only use for one-off lookups.
    static func evaluateOnDisk(path: String, sizeBytes: UInt64 = 0) -> ItemRecommendation {
        let modDate = (try? FileManager.default
            .attributesOfItem(atPath: path)[.modificationDate]) as? Date
        return evaluate(path: path, modificationDate: modDate, sizeBytes: sizeBytes)
    }
}

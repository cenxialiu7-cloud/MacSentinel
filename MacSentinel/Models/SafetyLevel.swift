import Foundation

/// Indicates how safe it is to delete a given item.
/// Pure-model file (no SwiftUI) — shared between the GUI app and the
/// MacSentinelMCP CLI target. View code lives in SafetyBadge.swift.
enum SafetyLevel: Int, Comparable, Codable {
    /// Completely safe — system/app regenerates this automatically on next launch.
    case safe = 0

    /// Generally safe — reversible and won't break anything, may briefly lose
    /// minor convenience state.
    case recommended = 1

    /// Use caution — reversible (Trash), but may force re-login or re-config.
    case caution = 2

    /// Risky — only delete if you understand the consequences.
    case risky = 3

    static func < (lhs: SafetyLevel, rhs: SafetyLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var label: String {
        switch self {
        case .safe:        return "可安全清除"
        case .recommended: return "建議清除"
        case .caution:     return "請評估後清除"
        case .risky:       return "謹慎操作"
        }
    }

    var shortLabel: String {
        switch self {
        case .safe:        return "安全"
        case .recommended: return "建議"
        case .caution:     return "注意"
        case .risky:       return "風險"
        }
    }

    var systemImage: String {
        switch self {
        case .safe:        return "checkmark.shield.fill"
        case .recommended: return "checkmark.circle.fill"
        case .caution:     return "exclamationmark.triangle.fill"
        case .risky:       return "exclamationmark.octagon.fill"
        }
    }

    /// One-sentence rationale shown in UI tooltips and MCP responses.
    var rationale: String {
        switch self {
        case .safe:
            return "這類檔案由系統或應用程式自動重建，清除後不會影響使用，重新開啟時會自動產生。"
        case .recommended:
            return "清除後不會影響應用程式功能，但可能會重置最近檔案、縮圖等便利狀態。"
        case .caution:
            return "可能會清除應用程式的設定或登入狀態，刪除後需重新登入或重新配置。"
        case .risky:
            return "可能影響系統運作或第三方驅動。除非確認來源，否則不建議移除。"
        }
    }

    /// String key used in JSON (for MCP / AI report consumption)
    var jsonKey: String {
        switch self {
        case .safe:        return "safe"
        case .recommended: return "recommended"
        case .caution:     return "caution"
        case .risky:       return "risky"
        }
    }
}

// MARK: - Heuristic Classifier (pure logic — no UI)

enum SafetyClassifier {

    /// Classify a filesystem path into a SafetyLevel based on well-known directory patterns.
    static func classify(path: String) -> SafetyLevel {
        let p = path.lowercased()

        let safePatterns = [
            "/library/caches/",
            "/derivedDdata",
            "/deriveddata",
            "/ios devicesupport/",
            "/coresimulator/caches/",
            "/.npm/_cacache",
            "/.cache/pip",
            "/library/caches/homebrew",
            "/library/caches/google",
            "/library/caches/bravesoftware",
            "/library/caches/com.brave.browser",
            "/library/caches/com.apple.safari",
            "/library/caches/firefox",
            "/library/caches/com.microsoft.edgemac",
            "/library/caches/ms-playwright",
            "/library/caches/org.swift.swiftpm",
            "/library/caches/com.apple.geoservices",
            "/library/caches/com.apple.helpd",
            "/library/caches/mediaanalysisd",
            "/library/application support/com.apple.wallpaper/aerials",
            "/library/webkit",
        ]
        if safePatterns.contains(where: { p.contains($0) }) {
            return .safe
        }

        let recommendedPatterns = [
            "/library/logs/",
            "/library/saved application state/",
            "/library/diagnosticreports/",
            "/library/crashreporter/",
            "/.crash",
            "/xcs/logs/",
            "/library/caches/com.apple.helpviewer",
        ]
        if recommendedPatterns.contains(where: { p.contains($0) }) {
            return .recommended
        }

        let riskyPatterns = [
            "/library/launchdaemons/",
            "/library/extensions/",
            "/system/library/",
        ]
        if riskyPatterns.contains(where: { p.contains($0) }) {
            return .risky
        }

        let cautionPatterns = [
            "/library/launchagents/",
            "/library/preferences/",
            "/library/application support/",
            "/library/containers/",
            "/library/group containers/",
            "/library/cookies/",
            "/library/httpstorages/",
        ]
        if cautionPatterns.contains(where: { p.contains($0) }) {
            return .caution
        }

        return .caution
    }

    static func classify(category: ResidualCategory) -> SafetyLevel {
        switch category {
        case .caches:             return .safe
        case .logs:               return .safe
        case .savedState:         return .recommended
        case .preferences:        return .caution
        case .applicationSupport: return .caution
        case .container:          return .caution
        case .groupContainer:     return .caution
        case .launchAgent:        return .caution
        case .launchDaemon:       return .risky
        case .other:              return .recommended
        }
    }

    static func classify(cacheCategory: CacheCategoryType) -> SafetyLevel {
        switch cacheCategory {
        case .browserCache: return .safe
        case .devToolCache: return .safe
        case .systemCache:  return .recommended
        case .mediaAssets:  return .safe
        case .appLogs:      return .safe
        case .otherJunk:    return .recommended
        }
    }
}

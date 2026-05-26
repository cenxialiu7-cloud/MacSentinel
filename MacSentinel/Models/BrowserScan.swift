import Foundation

// MARK: - Browser scan models

enum BrowserKind: String, Codable, CaseIterable {
    case chrome     = "Google Chrome"
    case brave      = "Brave"
    case edge       = "Microsoft Edge"
    case arc        = "Arc"
    case vivaldi    = "Vivaldi"
    case opera      = "Opera"
    case firefox    = "Firefox"
    case safari     = "Safari"

    var symbolName: String {
        switch self {
        case .safari, .firefox, .arc:   return "safari"
        default:                         return "globe"
        }
    }
}

enum ExtensionRiskLevel: String, Codable {
    case clean      // 0–39
    case lowRisk    // 40–69 (orange)
    case highRisk   // 70–99 (red)
    case blocked    // 100 (blocklist hit)

    var label: String {
        switch self {
        case .clean:    return "正常"
        case .lowRisk:  return "低風險"
        case .highRisk: return "高風險"
        case .blocked:  return "黑名單"
        }
    }
}

struct BrowserExtension: Identifiable, Codable {
    let id: String                       // extension ID (per-browser unique)
    let browser: BrowserKind
    let name: String
    let version: String
    let installPath: String
    let permissions: [String]
    let hostPermissions: [String]
    let isFromStore: Bool                // true = official Web Store
    let isEnabled: Bool
    let riskScore: Int                   // 0-100
    let riskLevel: ExtensionRiskLevel
    let riskFactors: [String]            // human-readable reasons
    let blocklistMatch: String?          // source if blocklisted
}

struct BrowserScanResult: Codable {
    var extensions: [BrowserExtension] = []
    var scanErrors: [String] = []        // per-browser errors (file not readable, etc.)

    var totalCount: Int { extensions.count }
    var blockedCount: Int { extensions.filter { $0.riskLevel == .blocked }.count }
    var highRiskCount: Int { extensions.filter { $0.riskLevel == .highRisk }.count }
    var lowRiskCount: Int { extensions.filter { $0.riskLevel == .lowRisk }.count }
}

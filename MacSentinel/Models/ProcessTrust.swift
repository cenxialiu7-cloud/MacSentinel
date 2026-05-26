import Foundation

// MARK: - Process Trust Model

/// 5-level trust classification for running processes.
/// L5 (best) → L1 (worst). Based on code signature, notarization, path,
/// and entitlements analysis.
enum ProcessTrustLevel: Int, Comparable, Codable {
    case l5_appleSystem    = 5   // Apple's own system processes
    case l4_notarizedThird = 4   // Verified third-party Developer ID + notarized
    case l3_signedNotNotarized = 3  // Has TeamID but not notarized
    case l2_adhocOrSelfSigned  = 2  // ad-hoc signature or odd path
    case l1_unsigned           = 1  // unsigned / invalid / impersonating system

    static func < (lhs: ProcessTrustLevel, rhs: ProcessTrustLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var shortLabel: String {
        switch self {
        case .l5_appleSystem:        return "Apple 系統"
        case .l4_notarizedThird:     return "已公證"
        case .l3_signedNotNotarized: return "已簽章"
        case .l2_adhocOrSelfSigned:  return "Ad-hoc"
        case .l1_unsigned:           return "高危"
        }
    }

    var symbolName: String {
        switch self {
        case .l5_appleSystem:        return "applelogo"
        case .l4_notarizedThird:     return "checkmark.shield.fill"
        case .l3_signedNotNotarized: return "shield.lefthalf.filled"
        case .l2_adhocOrSelfSigned:  return "exclamationmark.shield.fill"
        case .l1_unsigned:           return "xmark.shield.fill"
        }
    }

    var jsonKey: String {
        switch self {
        case .l5_appleSystem:        return "apple_system"
        case .l4_notarizedThird:     return "notarized_third_party"
        case .l3_signedNotNotarized: return "signed_not_notarized"
        case .l2_adhocOrSelfSigned:  return "adhoc_or_self_signed"
        case .l1_unsigned:           return "unsigned_or_invalid"
        }
    }
}

/// Static signing information about a binary on disk.
struct ProcessTrustInfo: Codable {
    let pid: Int32
    let executablePath: String
    let processName: String

    // Signing facts
    let trustLevel: ProcessTrustLevel
    let isSignatureValid: Bool       // SecStaticCodeCheckValidity passed
    let isAdHoc: Bool                // kSecCodeSignatureAdhoc flag set
    let teamIdentifier: String?      // Developer ID team (nil for ad-hoc/unsigned)
    let signingIdentifier: String?   // bundle ID from signature (CDHash 'ident')
    let authorityChain: [String]     // ["Developer ID Application: ...", "Developer ID CA", "Apple Root"]
    let isNotarized: Bool            // tickets in DB OR signature has notarization receipt
    let isHardenedRuntime: Bool      // kSecCodeSignatureRuntime flag

    // Risk surface
    let highRiskEntitlements: [String]  // matching our risky-entitlements list
    let allEntitlements: [String]       // full key list (values omitted for brevity)
    let cdHash: String?                 // hex string of kSecCodeInfoUnique

    // Heuristic flags
    let isPathSuspicious: Bool       // running from /tmp, ~/Library/<random>, /var/folders, etc.
    let isImpersonatingSystem: Bool  // name looks like system process but path wrong
    let reasons: [String]            // human-readable rationale lines

    var hasIssues: Bool {
        trustLevel <= .l2_adhocOrSelfSigned ||
        !highRiskEntitlements.isEmpty ||
        isImpersonatingSystem
    }
}

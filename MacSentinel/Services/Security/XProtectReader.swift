import Foundation

// MARK: - XProtectReader
//
// Reads Apple's built-in malware detection rules from
// /Library/Apple/System/Library/CoreServices/XProtect.bundle
// and surfaces them as a structured list. We do NOT run yara scans ourselves —
// macOS already does that automatically. We just expose what XProtect KNOWS
// about, so the user (and AI assistants) can correlate observed file names /
// processes with Apple's published malware family list.

struct XProtectRule: Identifiable, Codable {
    let id: String       // Rule name as used by Apple (e.g., MACOS.GOSEARCH22.B)
    let family: String?  // Best-effort: e.g., "GOSEARCH22"
    let matchers: [String]  // Strings found in the rule that hint at IOC patterns
}

struct XProtectInfo: Codable {
    let bundlePath: String
    let version: String?
    let ruleCount: Int
    let rules: [XProtectRule]
    let available: Bool
    let note: String
}

final class XProtectReader {

    static let shared = XProtectReader()
    private init() {}

    private let bundlePath = "/Library/Apple/System/Library/CoreServices/XProtect.bundle"
    private let yaraFilename = "XProtect.yara"
    private let metaFilename = "XProtect.meta.plist"

    func read() async -> XProtectInfo {
        let fm = FileManager.default
        guard fm.fileExists(atPath: bundlePath) else {
            return XProtectInfo(
                bundlePath: bundlePath, version: nil, ruleCount: 0, rules: [],
                available: false,
                note: "XProtect bundle not found at expected path; macOS may use a different location on this system."
            )
        }

        let resources = "\(bundlePath)/Contents/Resources"
        let yaraPath = "\(resources)/\(yaraFilename)"
        let metaPath = "\(resources)/\(metaFilename)"

        // Read version from Info.plist
        let infoPlistPath = "\(bundlePath)/Contents/Info.plist"
        var version: String?
        if let dict = NSDictionary(contentsOfFile: infoPlistPath) as? [String: Any] {
            version = (dict["CFBundleShortVersionString"] as? String)
                  ?? (dict["CFBundleVersion"] as? String)
        }

        guard let yaraText = try? String(contentsOfFile: yaraPath, encoding: .utf8) else {
            return XProtectInfo(
                bundlePath: bundlePath, version: version, ruleCount: 0, rules: [],
                available: false,
                note: "Cannot read XProtect.yara (may require Full Disk Access)."
            )
        }

        let rules = parseYaraRules(yaraText)
        _ = metaPath  // reserved for future meta.plist parsing

        return XProtectInfo(
            bundlePath: bundlePath, version: version, ruleCount: rules.count, rules: rules,
            available: true,
            note: "XProtect runs automatically against downloaded files. This list is Apple's current detection set; you don't need to act on it manually."
        )
    }

    // MARK: - Yara parsing
    //
    // We don't run a real yara engine — we just parse the rule headers:
    //   rule MACOS.SOMETHING : Family { strings: $a = "abc" condition: ... }
    // and pull out the rule name plus a sample of matchers.

    private func parseYaraRules(_ text: String) -> [XProtectRule] {
        var rules: [XProtectRule] = []
        var currentName: String?
        var currentFamily: String?
        var currentMatchers: [String] = []
        var depth = 0

        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // rule NAME : Family {
            if trimmed.hasPrefix("rule "), let openBrace = trimmed.firstIndex(of: "{") {
                let header = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 5)..<openBrace])
                let parts = header.split(separator: ":").map { $0.trimmingCharacters(in: .whitespaces) }
                currentName = parts.first
                currentFamily = parts.count > 1 ? parts[1] : nil
                currentMatchers = []
                depth = 1
                continue
            }

            if currentName != nil {
                // Track brace depth so nested {} (e.g. condition blocks) don't end the rule early
                depth += trimmed.filter { $0 == "{" }.count
                depth -= trimmed.filter { $0 == "}" }.count

                // Collect string matchers — lines like `$xxx = "literal"`
                if let eq = trimmed.range(of: "= \"") {
                    let afterEq = trimmed[eq.upperBound...]
                    if let closeQuote = afterEq.firstIndex(of: "\"") {
                        let literal = String(afterEq[..<closeQuote])
                        if !literal.isEmpty && literal.count <= 80 {
                            currentMatchers.append(literal)
                        }
                    }
                }

                // End of rule
                if depth <= 0 {
                    rules.append(XProtectRule(
                        id: currentName ?? "(unnamed)",
                        family: currentFamily,
                        matchers: currentMatchers.prefix(10).map { $0 }   // cap per-rule
                    ))
                    currentName = nil
                    currentFamily = nil
                    currentMatchers.removeAll()
                }
            }
        }
        return rules
    }
}

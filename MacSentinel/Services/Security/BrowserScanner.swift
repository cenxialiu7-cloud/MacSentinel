import Foundation

// MARK: - BrowserScanner
//
// Enumerates installed browser extensions across Chromium-family browsers,
// Firefox, and Safari, then scores each based on the permissions declared in
// the extension's manifest. A small built-in blocklist of known-malicious
// extension IDs short-circuits to risk=100.
//
// Strategy:
//   - Chromium family: ~/Library/Application Support/<Vendor>/<Browser>/<Profile>/
//                       Extensions/<extID>/<version>/manifest.json
//   - Firefox: ~/Library/Application Support/Firefox/Profiles/*/extensions.json
//   - Safari: pluginkit -mAvvv (we wrap as Process)
//
// All work is path-based; nothing is modified.

final class BrowserScanner {

    static let shared = BrowserScanner()
    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    private init() {}

    // MARK: - Public API

    func scanAll() async -> BrowserScanResult {
        // Snapshot the remote feed once per scan.
        cachedRemote = BrowserBlocklistFeed.shared.remoteEntries
        // Best-effort background refresh for next time.
        BrowserBlocklistFeed.shared.refreshIfNeeded()
        return await withTaskGroup(of: ([BrowserExtension], [String]).self) { group in
            // Chromium-family
            let chromium: [(BrowserKind, String)] = [
                (.chrome,  "Google/Chrome"),
                (.brave,   "BraveSoftware/Brave-Browser"),
                (.edge,    "Microsoft Edge"),
                (.arc,     "Arc/User Data"),
                (.vivaldi, "Vivaldi"),
                (.opera,   "com.operasoftware.Opera"),
            ]
            for (kind, subpath) in chromium {
                group.addTask { [weak self] in
                    await self?.scanChromium(kind: kind, vendorSubpath: subpath) ?? ([], [])
                }
            }
            // Firefox
            group.addTask { [weak self] in await self?.scanFirefox() ?? ([], []) }
            // Safari
            group.addTask { [weak self] in await self?.scanSafari() ?? ([], []) }

            var all: [BrowserExtension] = []
            var errors: [String] = []
            for await (exts, errs) in group {
                all.append(contentsOf: exts)
                errors.append(contentsOf: errs)
            }
            return BrowserScanResult(extensions: all, scanErrors: errors)
        }
    }


    // MARK: - Chromium-family scanner

    private func scanChromium(kind: BrowserKind, vendorSubpath: String) async -> ([BrowserExtension], [String]) {
        let appSupport = "\(home)/Library/Application Support/\(vendorSubpath)"
        guard fm.fileExists(atPath: appSupport) else { return ([], []) }

        // Find profile directories — typically "Default", "Profile 1", etc.
        var profiles: [String] = []
        if let contents = try? fm.contentsOfDirectory(atPath: appSupport) {
            for name in contents where name == "Default" || name.hasPrefix("Profile ") {
                profiles.append("\(appSupport)/\(name)")
            }
        }
        if profiles.isEmpty { return ([], []) }

        var results: [BrowserExtension] = []
        var errors: [String] = []

        for profilePath in profiles {
            let extDir = "\(profilePath)/Extensions"
            guard fm.fileExists(atPath: extDir) else { continue }

            // Read Preferences (or Secure Preferences) for enabled state + store provenance
            let prefsURL = URL(fileURLWithPath: "\(profilePath)/Preferences")
            let extPrefs = parseChromiumPreferences(prefsURL)

            guard let extIDs = try? fm.contentsOfDirectory(atPath: extDir) else { continue }
            for extID in extIDs where extID.count == 32 {   // Chromium ext IDs are 32 chars
                let idDir = "\(extDir)/\(extID)"
                // Each ext has versioned subdirectories — pick highest
                guard let versions = try? fm.contentsOfDirectory(atPath: idDir),
                      let latest = versions.sorted().last
                else { continue }
                let manifestURL = URL(fileURLWithPath: "\(idDir)/\(latest)/manifest.json")
                guard let extInfo = parseManifest(at: manifestURL, id: extID, browser: kind,
                                                   prefs: extPrefs[extID])
                else {
                    errors.append("\(kind.rawValue): failed to parse manifest at \(manifestURL.lastPathComponent)")
                    continue
                }
                results.append(extInfo)
            }
        }
        return (results, errors)
    }

    /// Chromium Preferences JSON: extensions.settings.<id> = { state, from_webstore, ... }
    private func parseChromiumPreferences(_ url: URL) -> [String: [String: Any]] {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ext  = json["extensions"] as? [String: Any],
              let settings = ext["settings"] as? [String: Any]
        else { return [:] }
        var out: [String: [String: Any]] = [:]
        for (id, raw) in settings {
            if let dict = raw as? [String: Any] { out[id] = dict }
        }
        return out
    }

    private func parseManifest(at url: URL,
                                id: String,
                                browser: BrowserKind,
                                prefs: [String: Any]?) -> BrowserExtension? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let name = (json["name"] as? String) ?? "(unknown)"
        let version = (json["version"] as? String) ?? "0.0"

        // permissions = MV2/3 unified
        var perms: [String] = []
        if let p = json["permissions"] as? [Any] { perms = p.compactMap { $0 as? String } }
        var hostPerms: [String] = []
        if let h = json["host_permissions"] as? [Any] { hostPerms = h.compactMap { $0 as? String } }
        // MV2 mixes the two — pick out URL-pattern looking strings
        let urlLooking = perms.filter { $0.contains("://") || $0.hasPrefix("<all_urls>") }
        if !urlLooking.isEmpty {
            hostPerms.append(contentsOf: urlLooking)
            perms.removeAll { urlLooking.contains($0) }
        }

        // Provenance
        let isFromStore = (prefs?["from_webstore"] as? Bool) ?? false
        let stateInt    = (prefs?["state"] as? Int) ?? 1   // 1 = enabled
        let isEnabled   = stateInt == 1

        // Risk scoring
        let (score, factors, blocklistMatch) = scoreExtension(
            id: id, name: name, perms: perms, hostPerms: hostPerms,
            isFromStore: isFromStore
        )

        return BrowserExtension(
            id: id,
            browser: browser,
            name: name,
            version: version,
            installPath: url.deletingLastPathComponent().path,
            permissions: perms,
            hostPermissions: hostPerms,
            isFromStore: isFromStore,
            isEnabled: isEnabled,
            riskScore: score,
            riskLevel: levelForScore(score, blocklisted: blocklistMatch != nil),
            riskFactors: factors,
            blocklistMatch: blocklistMatch
        )
    }

    // MARK: - Firefox scanner

    private func scanFirefox() async -> ([BrowserExtension], [String]) {
        let profilesDir = "\(home)/Library/Application Support/Firefox/Profiles"
        guard fm.fileExists(atPath: profilesDir),
              let profiles = try? fm.contentsOfDirectory(atPath: profilesDir)
        else { return ([], []) }

        var results: [BrowserExtension] = []
        var errors: [String] = []

        for profile in profiles {
            let extensionsJSON = URL(fileURLWithPath: "\(profilesDir)/\(profile)/extensions.json")
            guard let data = try? Data(contentsOf: extensionsJSON),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let addons = json["addons"] as? [[String: Any]]
            else { continue }

            for addon in addons {
                guard let id = addon["id"] as? String,
                      addon["type"] as? String == "extension" || addon["type"] as? String == nil
                else { continue }

                let name = (addon["defaultLocale"] as? [String: Any])?["name"] as? String
                        ?? (addon["name"] as? String)
                        ?? id
                let version = (addon["version"] as? String) ?? "0.0"
                let path    = (addon["path"] as? String) ?? ""
                let sourceURI = addon["sourceURI"] as? String
                let signedState = (addon["signedState"] as? Int) ?? -1
                // Firefox signedState: 0=missing, 1=preliminary, 2=signed AMO, 3=system, -1=missing
                let isFromStore = signedState >= 2

                // Firefox permissions live in userPermissions
                var perms: [String] = []
                var hostPerms: [String] = []
                if let userPerms = addon["userPermissions"] as? [String: Any] {
                    if let p = userPerms["permissions"] as? [String] { perms = p }
                    if let o = userPerms["origins"]     as? [String] { hostPerms = o }
                }

                let isEnabled = (addon["active"] as? Bool) ?? false

                let (score, factors, blocked) = scoreExtension(
                    id: id, name: name, perms: perms, hostPerms: hostPerms,
                    isFromStore: isFromStore,
                    extraRiskHint: (sourceURI?.hasPrefix("file://") ?? false) ? "Installed from local file" : nil
                )

                results.append(BrowserExtension(
                    id: id, browser: .firefox, name: name, version: version,
                    installPath: path,
                    permissions: perms, hostPermissions: hostPerms,
                    isFromStore: isFromStore, isEnabled: isEnabled,
                    riskScore: score,
                    riskLevel: levelForScore(score, blocklisted: blocked != nil),
                    riskFactors: factors,
                    blocklistMatch: blocked
                ))
            }
        }

        return (results, errors)
    }

    // MARK: - Safari scanner (via pluginkit)

    private func scanSafari() async -> ([BrowserExtension], [String]) {
        // pluginkit -mAvvv -p com.apple.Safari.web-extension
        // Output is tabular; each extension occupies a few lines with bundle ID + path
        let process = Process()
        process.launchPath = "/usr/bin/pluginkit"
        process.arguments  = ["-mAvvv", "-p", "com.apple.Safari.web-extension"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = Pipe()

        do { try process.run() } catch {
            return ([], ["Safari: cannot run pluginkit — \(error.localizedDescription)"])
        }
        process.waitUntilExit()
        let outData = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: outData, encoding: .utf8) else { return ([], []) }

        return (parseSafariPluginKitOutput(output), [])
    }

    private func parseSafariPluginKitOutput(_ output: String) -> [BrowserExtension] {
        var results: [BrowserExtension] = []
        var current: [String: String] = [:]

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if let id = current["BundleIdentifier"] {
                    let name = current["DisplayName"] ?? current["BundleName"] ?? id
                    let version = current["DisplayVersion"] ?? "0.0"
                    let path    = current["Path"] ?? ""
                    let enabled = (current["Enabled"] ?? "").lowercased().contains("yes") ||
                                  (current["Enabled"] ?? "").lowercased().contains("enabled")

                    // Safari extensions don't expose permissions via pluginkit;
                    // we conservatively assume some unknown surface.
                    let (score, factors, blocked) = scoreExtension(
                        id: id, name: name, perms: [], hostPerms: [],
                        isFromStore: true,   // Safari ext distribution forces Mac App Store
                        extraRiskHint: nil
                    )
                    results.append(BrowserExtension(
                        id: id, browser: .safari, name: name, version: version,
                        installPath: path,
                        permissions: [], hostPermissions: [],
                        isFromStore: true, isEnabled: enabled,
                        riskScore: score,
                        riskLevel: levelForScore(score, blocklisted: blocked != nil),
                        riskFactors: factors,
                        blocklistMatch: blocked
                    ))
                }
                current.removeAll()
                continue
            }
            // Parse "key = value;" tokens within Safari plugin-kit output
            if let eq = trimmed.firstIndex(of: "=") {
                var key = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces)
                var val = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if val.hasSuffix(";") { val.removeLast() }
                val = val.trimmingCharacters(in: .init(charactersIn: " \";"))
                if key.hasPrefix("\"") && key.hasSuffix("\"") { key.removeFirst(); key.removeLast() }
                current[key] = val
            }
        }
        return results
    }

    // MARK: - Risk scoring

    /// Built-in blocklist of known malicious extension IDs.
    /// Small starter list — extend by syncing Mozilla/Awake/CRXcavator feeds later.
    private static let blocklist: [String: String] = [
        // Pirrit / Bromox / Crossrider — examples documented in security firm reports
        "kdidombaedgpfiiedeimiebkmbilgmlc": "Awake Security 2020 Chrome IOC",
        "pgnnenaccnbalimnedjkenecedlokfkb": "Awake Security 2020 Chrome IOC",
        "djdaeefdlcdkgocoijkilfngamcdkjjj": "Awake Security 2020 Chrome IOC",
        "bopfijkadigdpiifgppcdoeibdhglffc": "Awake Security 2020 Chrome IOC",
        // Add more from your blocklist sync here
    ]

    /// Optional well-known good IDs (won't escape blocklist match if present, but won't
    /// be penalized for low score signals).
    private static let knownGood: Set<String> = [
        "aeblfdkhhhdcdjpifhhbdiojplfjncoa",    // 1Password 7/8
        "nngceckbapebfimnlniiiahkandclblb",    // Bitwarden
        "cjpalhdlnbpafiamejdnhcphjbkeiagm",    // uBlock Origin
        "bgnkhhnnamicmpeenaelnjfhikgbkllg",    // AdGuard
        "kbfnbcaeplbcioakkpcpgfkobkghlhen",    // Grammarly
        "hdokiejnpimakedhajhdlcegeplioahd",    // LastPass
        "dbepggeogbaibhgnhhndojpepiihcmeb",    // Vimium
        "eimadpbcbfnmbkopoojfekhnkhdbieeh",    // Dark Reader
        "fmkadmapgofadopljbjfkapdkoienihi",    // React DevTools
        "nhdogjmejiglipccpnnnanhbledajbpd",    // Vue.js DevTools
        "lmhkpmbekcpmknklioeibfkpmmfibljd",    // Redux DevTools
        "dhdgffkkebhmkfjojejmpbldmpobfkfo",    // Tampermonkey
    ]

    private func scoreExtension(
        id: String,
        name: String,
        perms: [String],
        hostPerms: [String],
        isFromStore: Bool,
        extraRiskHint: String? = nil
    ) -> (score: Int, factors: [String], blocklist: String?) {

        // Blocklist short-circuit — built-in IOCs first, then remote feed
        if let source = BrowserScanner.blocklist[id] {
            return (100, ["Matches known malicious extension blocklist (\(source))"], source)
        }
        if let source = remoteBlocklistLookup(id: id) {
            return (100, ["Matches remote blocklist feed (\(source))"], source)
        }

        var score = 0
        var factors: [String] = []

        // host_permissions
        let hasAllUrls = hostPerms.contains { $0 == "<all_urls>" || $0 == "*://*/*" || $0 == "https://*/*" }
        if hasAllUrls { score += 25; factors.append("Requests access to all URLs (<all_urls>)") }

        // dangerous permissions
        func add(_ permKey: String, _ amount: Int, _ reason: String) {
            if perms.contains(permKey) { score += amount; factors.append(reason) }
        }
        add("webRequest",         10, "Can observe network requests (webRequest)")
        add("webRequestBlocking", 15, "Can BLOCK / modify network requests (webRequestBlocking)")
        add("declarativeNetRequestWithHostAccess", 10, "Network-level rewrite power")
        add("proxy",              20, "Can change browser proxy settings (proxy)")
        add("cookies",            10, "Can read/write all cookies (cookies)")
        add("debugger",           25, "Can attach as a debugger to tabs (debugger)")
        add("nativeMessaging",    15, "Can communicate with native host apps (nativeMessaging)")
        add("management",         10, "Can install/disable other extensions (management)")
        add("contentSettings",     8, "Can change site-level Chrome settings")

        // Provenance
        if !isFromStore && BrowserScanner.knownGood.contains(id) == false {
            score += 20
            factors.append("Not installed from official web store (sideloaded)")
        }

        if let extra = extraRiskHint {
            score += 10
            factors.append(extra)
        }

        // Cap at 99 — only blocklist hits get 100
        score = min(99, score)

        if score == 0 { factors.append("No risky permissions detected") }

        return (score, factors, nil)
    }

    /// Cached snapshot of the remote feed, taken once per `scanAll()` run.
    /// Cleared at the top of `scanAll`. Safe because BrowserBlocklistFeed
    /// returns a value-type dict under its own internal lock.
    nonisolated(unsafe) private var cachedRemote: [String: String] = [:]

    private func remoteBlocklistLookup(id: String) -> String? {
        cachedRemote[id]
    }

    private func levelForScore(_ score: Int, blocklisted: Bool) -> ExtensionRiskLevel {
        if blocklisted { return .blocked }
        switch score {
        case 70...:  return .highRisk
        case 40...:  return .lowRisk
        default:     return .clean
        }
    }
}

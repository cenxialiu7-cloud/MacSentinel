import Foundation

// MARK: - NetworkScanner
//
// Detects network-layer hijack indicators by reading public system files and
// querying `scutil` / `networksetup`. Never modifies anything.

final class NetworkScanner {

    static let shared = NetworkScanner()
    private init() {}

    func scan() async -> NetworkScanResult {
        async let hosts = checkHostsFile()
        async let dns   = checkDNS()
        async let pac   = checkPAC()
        async let daemons = checkLaunchDaemons()

        let (h, d, p, ld) = await (hosts, dns, pac, daemons)

        var result = NetworkScanResult()
        result.hostsLineCount = h.lineCount
        result.dnsServers     = d.servers
        result.pacURL         = p.pacURL
        result.totalLaunchDaemonsChecked = ld.checked
        result.anomalies      = h.anomalies + d.anomalies + p.anomalies + ld.anomalies
        return result
    }

    // MARK: - /etc/hosts

    /// Sensitive domains that should typically resolve via DNS, not be
    /// overridden locally. Hits here are highly suspicious unless the user
    /// runs a corporate dev environment.
    private static let sensitiveHostnames: [String] = [
        "google.com", "www.google.com", "apple.com", "icloud.com",
        "github.com", "facebook.com", "youtube.com", "amazon.com",
        "paypal.com", "anthropic.com", "openai.com", "microsoft.com",
        "live.com", "office.com", "twitter.com", "x.com",
    ]

    private func checkHostsFile() async -> (lineCount: Int, anomalies: [NetworkAnomaly]) {
        let path = "/etc/hosts"
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return (0, [])
        }
        var anomalies: [NetworkAnomaly] = []
        let lines = content.components(separatedBy: "\n")

        for (idx, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let cols = line.split(whereSeparator: { $0.isWhitespace })
            guard cols.count >= 2 else { continue }
            let ip = String(cols[0])
            // Loopback is fine: 127.0.0.1, ::1, 0.0.0.0 (the standard /etc/hosts skeleton)
            let standardIPs: Set<String> = ["127.0.0.1", "255.255.255.255", "::1",
                                             "fe80::1%lo0", "ff00::0", "ff02::1",
                                             "ff02::2", "ff02::3"]

            for col in cols.dropFirst() {
                let host = String(col)
                if NetworkScanner.sensitiveHostnames.contains(host) {
                    let isLoopback = ip.hasPrefix("127.") || ip == "0.0.0.0" || ip == "::1"
                    let severity: NetworkSeverity = isLoopback ? .warning : .critical
                    anomalies.append(NetworkAnomaly(
                        kind: .suspiciousHostsEntry,
                        severity: severity,
                        title: "/etc/hosts 包含可疑映射：\(host)",
                        detail: isLoopback
                            ? "把 \(host) 指向本機，可能是廣告攔截器或除錯用途；惡意軟體也常用此方式封鎖安全更新通道。"
                            : "把 \(host) 指向非預期的 IP \(ip)。這通常是劫持行為。",
                        evidence: "/etc/hosts:\(idx + 1) → \(line)",
                        remediation: "編輯 /etc/hosts（需 sudo），確認此條目來源並視需要刪除。可先備份：sudo cp /etc/hosts /etc/hosts.bak"
                    ))
                } else if !standardIPs.contains(ip) && !ip.hasPrefix("127.") && !ip.hasPrefix("0.") {
                    // Generic non-standard override (no severity bump unless sensitive)
                    if anomalies.count < 50 {  // cap
                        anomalies.append(NetworkAnomaly(
                            kind: .suspiciousHostsEntry,
                            severity: .info,
                            title: "/etc/hosts 自訂條目：\(host)",
                            detail: "已被本機 hosts 檔覆寫為 \(ip)。若不熟悉此條目來源，建議審視。",
                            evidence: "/etc/hosts:\(idx + 1) → \(line)",
                            remediation: "確認此覆寫是否為你自己加入；如否，移除該行。"
                        ))
                    }
                }
            }
        }
        return (lines.count, anomalies)
    }

    // MARK: - DNS

    private func checkDNS() async -> (servers: [String], anomalies: [NetworkAnomaly]) {
        let output = runShell("/usr/sbin/scutil", args: ["--dns"])
        var servers: [String] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("nameserver["),
               let colon = trimmed.firstIndex(of: ":") {
                let ip = trimmed[trimmed.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                servers.append(ip)
            }
        }
        let unique = Array(Set(servers)).sorted()

        // Default Apple DNS includes private addresses pushed by DHCP (router)
        // or major public resolvers (8.8.8.8, 1.1.1.1, 9.9.9.9). Treat anything
        // EXOTIC as worth informing about.
        let wellKnownPublic: Set<String> = [
            "8.8.8.8", "8.8.4.4", "1.1.1.1", "1.0.0.1",
            "9.9.9.9", "149.112.112.112",
            "208.67.222.222", "208.67.220.220",
        ]
        var anomalies: [NetworkAnomaly] = []
        for ip in unique where !isPrivateRange(ip) && !wellKnownPublic.contains(ip) && !ip.contains(":") {
            anomalies.append(NetworkAnomaly(
                kind: .customDNS,
                severity: .info,
                title: "使用自訂公共 DNS：\(ip)",
                detail: "你目前使用的其中一個 DNS 伺服器不在常見大廠（Google/Cloudflare/Quad9/OpenDNS）清單中。若不熟悉此 IP，請審視「系統設定 → 網路 → 詳細資料 → DNS」。",
                evidence: ip,
                remediation: "系統設定 → 網路 → 點選網路介面 → 詳細資料 → DNS，移除可疑伺服器。"
            ))
        }
        return (unique, anomalies)
    }

    /// Return true if the IP is within RFC1918 / link-local / loopback ranges.
    private func isPrivateRange(_ ip: String) -> Bool {
        if ip.hasPrefix("10.") { return true }
        if ip.hasPrefix("192.168.") { return true }
        if ip.hasPrefix("127.") { return true }
        if ip.hasPrefix("169.254.") { return true }
        if ip.hasPrefix("172.") {
            // 172.16.0.0 - 172.31.255.255
            let parts = ip.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        if ip.contains(":") { return true }   // ignore IPv6 link-local for now
        return false
    }

    // MARK: - PAC

    private func checkPAC() async -> (pacURL: String?, anomalies: [NetworkAnomaly]) {
        // networksetup -getautoproxyurl Wi-Fi (and Ethernet)
        let interfaces = listNetworkServices()
        var anomalies: [NetworkAnomaly] = []
        var foundPAC: String?
        for iface in interfaces {
            let out = runShell("/usr/sbin/networksetup",
                               args: ["-getautoproxyurl", iface])
            // Output: "URL: http://... \n Enabled: Yes"
            if out.contains("Enabled: Yes") {
                let urlLine = out.components(separatedBy: "\n").first { $0.hasPrefix("URL:") }
                let url = urlLine?.replacingOccurrences(of: "URL: ", with: "") ?? "<unknown>"
                foundPAC = url
                anomalies.append(NetworkAnomaly(
                    kind: .autoProxyConfigured,
                    severity: .warning,
                    title: "啟用了自動代理（PAC）：\(iface)",
                    detail: "PAC 檔可決定每個請求走哪個代理。惡意 PAC 能把流量導向攻擊者控制的中繼。",
                    evidence: "interface=\(iface), URL=\(url)",
                    remediation: "系統設定 → 網路 → \(iface) → 詳細資料 → 代理 → 取消「自動代理組態」"
                ))
            }
        }
        return (foundPAC, anomalies)
    }

    private func listNetworkServices() -> [String] {
        let out = runShell("/usr/sbin/networksetup", args: ["-listallnetworkservices"])
        return out.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("An asterisk") }
    }

    // MARK: - LaunchDaemons (transparent proxy / suspicious system-wide hooks)

    private func checkLaunchDaemons() async -> (checked: Int, anomalies: [NetworkAnomaly]) {
        // Only look at /Library/LaunchDaemons — system daemons in /System/Library
        // are SIP-protected and not interesting.
        let dir = "/Library/LaunchDaemons"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            return (0, [])
        }
        var anomalies: [NetworkAnomaly] = []
        var checked = 0
        for filename in contents where filename.hasSuffix(".plist") {
            checked += 1
            let path = "\(dir)/\(filename)"
            guard let plist = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
            let label = (plist["Label"] as? String) ?? filename
            let programArgs = (plist["ProgramArguments"] as? [String]) ?? []
            let program = (plist["Program"] as? String) ?? programArgs.first ?? ""

            // Heuristic: if it references a known proxy/redirect binary, flag it
            let signature = (program + " " + programArgs.joined(separator: " ")).lowercased()
            let suspiciousTokens = ["proxy", "redsocks", "tproxy", "mitmproxy", "charles", "fiddler",
                                     "snitch", "transparent", "intercept"]
            if suspiciousTokens.contains(where: { signature.contains($0) }) {
                anomalies.append(NetworkAnomaly(
                    kind: .suspiciousLaunchDaemonProxy,
                    severity: .warning,
                    title: "可疑的 LaunchDaemon：\(label)",
                    detail: "此啟動項目的程式名稱或參數含有疑似網路攔截工具的關鍵字。請確認是否為你安裝的合法工具（如 Charles / Little Snitch）。",
                    evidence: "\(path) → Program=\(program)",
                    remediation: "若不認識此啟動項目：sudo launchctl unload \(path)，然後 sudo rm \(path)（建議先備份）。"
                ))
            }
        }
        return (checked, anomalies)
    }

    // MARK: - Shell helper

    private func runShell(_ launchPath: String, args: [String]) -> String {
        let process = Process()
        process.launchPath = launchPath
        process.arguments  = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError  = Pipe()
        do { try process.run() } catch { return "" }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

import Foundation

// MARK: - Network scan models

enum NetworkAnomalyKind: String, Codable {
    case suspiciousHostsEntry        // /etc/hosts contains override for sensitive domain
    case customDNS                    // user has configured a non-stock DNS server
    case autoProxyConfigured          // PAC URL set
    case suspiciousLaunchDaemonProxy  // a LaunchDaemon implements a transparent proxy
}

enum NetworkSeverity: String, Codable {
    case info      // informational
    case warning   // worth reviewing
    case critical  // immediate action recommended

    var label: String {
        switch self {
        case .info: return "資訊"
        case .warning: return "警告"
        case .critical: return "嚴重"
        }
    }
}

struct NetworkAnomaly: Identifiable, Codable {
    let id = UUID()
    let kind: NetworkAnomalyKind
    let severity: NetworkSeverity
    let title: String
    let detail: String
    let evidence: String          // the actual line / value found
    let remediation: String       // human-readable suggested fix

    enum CodingKeys: String, CodingKey {
        case id, kind, severity, title, detail, evidence, remediation
    }
}

struct NetworkScanResult: Codable {
    var anomalies: [NetworkAnomaly] = []
    var hostsLineCount: Int = 0
    var dnsServers: [String] = []
    var pacURL: String?
    var totalLaunchDaemonsChecked: Int = 0

    var anyCritical: Bool { anomalies.contains { $0.severity == .critical } }
}

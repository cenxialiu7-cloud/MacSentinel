import Foundation

enum ByteFormatter {
    static func format(_ bytes: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(bytes))
    }

    /// Format as speed: "12.3 MB/s"
    static func formatSpeed(_ bytesPerSec: Double) -> String {
        let abs = Swift.abs(bytesPerSec)
        switch abs {
        case 1_000_000_000...:
            return String(format: "%.1f GB/s", abs / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.1f MB/s", abs / 1_000_000)
        case 1_000...:
            return String(format: "%.1f KB/s", abs / 1_000)
        default:
            return String(format: "%.0f B/s", abs)
        }
    }

    /// Format percentage: "34.2%"
    static func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value)
    }

    /// Format temperature
    static func formatTemp(_ celsius: Double) -> String {
        guard celsius >= 0 else { return "—" }
        return String(format: "%.0f°C", celsius)
    }

    /// Format RPM
    static func formatRPM(_ rpm: Double) -> String {
        guard rpm >= 0 else { return "—" }
        return String(format: "%.0f RPM", rpm)
    }
}
